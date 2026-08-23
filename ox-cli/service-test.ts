import { isDeepStrictEqual } from "node:util";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { ChromeBrowser } from "./chrome/browser.ts";
import { ChromeServiceSession } from "./chrome/service.ts";
import { createServiceRuntime } from "./service-runtime.ts";
import { type ServiceManifest } from "./service-manifest.ts";
import type { ReplayCaseDefinition } from "../tests/services/replay/types.ts";
import {
  auditServiceFixtures,
  readReplayCaseDefinitions,
  writeServiceReplayCase,
  type ServiceReplayCase,
} from "../tests/services/replay/fixtures.ts";
import {
  sanitizeRecordedHar,
  selectRecordedRequestOccurrences,
  selectRecordedRequests,
  startRecordingProxy,
  startReplayProxy,
  type RecordedRequest,
} from "../tests/services/replay/proxy.ts";
import { fail, type CliContext } from "./lib.ts";

type Runtime = "chrome" | "ios";

type Options = {
  command: "import" | "record" | "replay";
  selector?: string;
  runtime: Runtime;
  proxyPort?: number;
  timeoutMs: number;
  args?: unknown;
  profileDir?: string;
  allowLiveWrite: boolean;
  update: boolean;
  harPath?: string;
  requests: RecordedRequest[];
  allowPartial: boolean;
  repository?: string;
  source?: string;
};

export async function testService(args: string[], context: CliContext): Promise<void> {
  if (args.includes("-h") || args.includes("--help")) {
    printUsage();
    return;
  }
  const modes = ["--import", "--record"].filter((mode) => args.includes(mode));
  if (modes.length > 1) fail(`${modes.join(", ")} cannot be combined`);
  const command = modes[0]?.slice(2) ?? "replay";
  const rest = args.filter((argument) => !modes.includes(argument));
  await runServices([
    command,
    ...rest,
    "--runtime", context.runtime,
    ...(context.repository ? ["--repository", context.repository] : []),
    ...(Bun.env.OX_SERVER_SOURCE ? ["--source", Bun.env.OX_SERVER_SOURCE] : []),
  ]);
}

async function runServices(args: string[]): Promise<void> {
  const options = parseOptions(args);
  if (options.command === "import") {
    await importCase(options);
    return;
  }
  if (options.command === "record") {
    await recordCase(options);
    return;
  }
  if (options.runtime !== "ios") throw new Error("service replay runs only in the iOS Simulator");
  const audit = await auditServiceFixtures(requiredSource(options));
  const selected = selectCases(audit.cases, options.selector);
  const selectedErrors = options.selector
    ? audit.errors.filter((error) => errorMatchesSelector(error, options.selector!))
    : audit.errors;
  const relevantErrors = options.allowPartial
    ? selectedErrors.filter((error) => !error.startsWith("missing replay case for "))
    : selectedErrors;
  if (relevantErrors.length) {
    for (const error of relevantErrors) console.error(`FAIL ${error}`);
    process.exitCode = 1;
    return;
  }
  if (selected.length === 0) throw new Error(`no replay cases matched ${options.selector ?? "the fixture corpus"}`);
  const tempDir = mkdtempSync(join(tmpdir(), "ox-service-replay-"));
  try {
    const proxyConfigurationDir = join(tmpdir(), "ox-service-replay", safePathComponent(requiredDevice()), "mitmproxy");
    const proxy = await startReplayProxy(selected, tempDir, options.proxyPort, proxyConfigurationDir);
    try {
      const results = await replayIOS(selected, proxy.caCertificatePath, options.timeoutMs);
      for (const result of results) console.log(`${result.ok ? "PASS" : "FAIL"} ${result.label}${result.detail ? ` ${result.detail}` : ""}`);
      const failed = results.filter((result) => !result.ok);
      console.log(`Service replay ${results.length - failed.length}/${results.length} passed in the iOS Simulator`);
      if (failed.length) process.exitCode = 1;
    } finally {
      await proxy.stop();
    }
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

type CaseResult = { ok: boolean; label: string; detail?: string };

async function importCase(options: Options): Promise<void> {
  const [domain, actionID, rawName] = options.selector?.split(":") ?? [];
  if (!domain || !actionID) throw new Error("import requires domain:action[:case]");
  if (!options.harPath) throw new Error("import requires --har path");
  if (!existsSync(options.harPath)) throw new Error(`HAR does not exist: ${options.harPath}`);
  const manifest = await sourceManifest(requiredSource(options), domain);
  const action = manifest.actions.find((candidate) => candidate.id === actionID);
  if (!action) throw new Error(`unknown action ${domain}:${actionID}`);
  const args = options.args ?? action.defaultArgs;
  if (args === undefined) throw new Error(`${domain}:${actionID} has no defaultArgs; pass --args '<json>'`);
  const name = rawName || "default";
  const stem = name === "default" ? actionID : `${actionID}.${name}`;
  assertCaseWritable(requiredSource(options), domain, actionID, name, options.update);
  const casePath = join(sourceDirectory(requiredSource(options), domain), "replay.ts");

  const requests = [
    { method: "GET", url: manifest.baseUrl! },
    ...options.requests,
  ];
  const raw = await Bun.file(options.harPath).json();
  const selected = selectRecordedRequestOccurrences(raw, requests);
  const sanitized = sanitizeRecordedHar(selected);
  const tempDir = mkdtempSync(join(tmpdir(), "ox-service-import-"));
  try {
    const temporaryHarPath = join(tempDir, `${stem}.har`);
    await Bun.write(temporaryHarPath, JSON.stringify(sanitized.har));
    const replay = {
      ignoreQueryParameters: sanitized.ignoreQueryParameters,
      ignoreBodyParameters: sanitized.ignoreBodyParameters,
      matchHeaders: [],
    };
    const fixture: ServiceReplayCase = {
      domain,
      action: actionID,
      name,
      args,
      expected: { output: null },
      harPath: temporaryHarPath,
      casePath,
      replay,
    };
    const proxy = await startReplayProxy([fixture], tempDir, options.proxyPort);
    let output: unknown;
    try {
      output = await invokeChromeAction(fixture, proxy.port, tempDir, options.timeoutMs, requiredRepository(options));
    } finally {
      await proxy.stop();
    }
    const result: ReplayCaseDefinition = { action: actionID, name, args, output };
    if (replay.ignoreQueryParameters.length || replay.ignoreBodyParameters.length) {
      result.replay = {
        ...(replay.ignoreQueryParameters.length
          ? { ignoreQueryParameters: replay.ignoreQueryParameters }
          : {}),
        ...(replay.ignoreBodyParameters.length
          ? { ignoreBodyParameters: replay.ignoreBodyParameters }
          : {}),
      };
    }
    const written = await writeServiceReplayCase(requiredSource(options), domain, result, sanitized.har, options.update);
    console.log(`Imported ${domain}:${actionID}:${name}`);
    console.log(`  ${written.casePath}`);
    console.log(`  ${written.harPath}`);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

async function recordCase(options: Options): Promise<void> {
  const [domain, actionID, rawName] = options.selector?.split(":") ?? [];
  if (!domain || !actionID) throw new Error("record requires domain:action[:case]");
  const manifest = await sourceManifest(requiredSource(options), domain);
  const action = manifest.actions.find((candidate) => candidate.id === actionID);
  if (!action) throw new Error(`unknown action ${domain}:${actionID}`);
  if (action.requireApproval && !options.allowLiveWrite) {
    throw new Error(`${domain}:${actionID} requires approval; create its HAR manually or pass --allow-live-write to authorize a real recording mutation`);
  }
  const args = options.args ?? action.defaultArgs;
  if (args === undefined) throw new Error(`${domain}:${actionID} has no defaultArgs; pass --args '<json>'`);
  const name = rawName || "default";
  const stem = name === "default" ? actionID : `${actionID}.${name}`;
  assertCaseWritable(requiredSource(options), domain, actionID, name, options.update);

  const tempDir = mkdtempSync(join(tmpdir(), "ox-service-record-"));
  const profileDir = options.profileDir ?? join(tempDir, "chrome-profile");
  const existing = await ChromeBrowser.connect({ profileDir, launch: false, timeoutMs: 500 });
  if (existing) {
    existing.close();
    throw new Error(`Chrome is already using ${profileDir}; close it so recording cannot bypass the proxy`);
  }
  try {
    const proxy = await startRecordingProxy(tempDir, options.proxyPort);
    let output: unknown;
    const requestsBySession = new Map<string, RecordedRequest[]>();
    try {
      const browser = await ChromeBrowser.connect({
        profileDir,
        timeoutMs: options.timeoutMs,
        launchArguments: [
          `--proxy-server=http://127.0.0.1:${proxy.port}`,
          "--disable-quic",
          "--disable-background-networking",
          "--disable-component-update",
          "--ignore-certificate-errors",
        ],
      });
      if (!browser) throw new Error("Chrome did not start");
      const stopRecordingRequests = browser.cdp.on("Network.requestWillBeSent", (params, sessionID) => {
        if (!sessionID) return;
        const request = (params as { request?: { method?: unknown; url?: unknown } }).request;
        if (typeof request?.method !== "string" || typeof request.url !== "string") return;
        const current = requestsBySession.get(sessionID) ?? [];
        current.push({ method: request.method, url: request.url });
        requestsBySession.set(sessionID, current);
      });
      try {
        const session = await ChromeServiceSession.open(browser, domain, options.timeoutMs, undefined, requiredRepository(options));
        await browser.cdp.send("Network.enable", {}, session.sessionId, options.timeoutMs);
        await session.reload(options.timeoutMs);
        output = await session.invoke(actionID, args, action.requireApproval, options.timeoutMs);
        const requests = requestsBySession.get(session.sessionId) ?? [];
        if (requests.length === 0) throw new Error("Chrome reported no service-page requests");
        requestsBySession.set("selected", requests);
      } finally {
        stopRecordingRequests();
        await browser.cdp.send("Browser.close", {}, undefined, 5_000).catch(() => {});
        browser.close();
      }
    } finally {
      await proxy.stop();
    }

    const selectedHar = selectRecordedRequests(
      JSON.parse(readFileSync(proxy.harPath, "utf8")),
      requestsBySession.get("selected") ?? [],
    );
    const sanitized = sanitizeRecordedHar(selectedHar);
    const fixture: ReplayCaseDefinition = { action: actionID, name, args, output };
    if (sanitized.ignoreQueryParameters.length || sanitized.ignoreBodyParameters.length) {
      fixture.replay = {
        ...(sanitized.ignoreQueryParameters.length
          ? { ignoreQueryParameters: sanitized.ignoreQueryParameters }
          : {}),
        ...(sanitized.ignoreBodyParameters.length
          ? { ignoreBodyParameters: sanitized.ignoreBodyParameters }
          : {}),
      };
    }
    const written = await writeServiceReplayCase(requiredSource(options), domain, fixture, sanitized.har, options.update);
    console.log(`Recorded ${domain}:${actionID}:${name}`);
    console.log(`  ${written.casePath}`);
    console.log(`  ${written.harPath}`);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

async function invokeChromeAction(
  fixture: ServiceReplayCase,
  proxyPort: number,
  tempDir: string,
  timeoutMs: number,
  repository: string,
): Promise<unknown> {
  const browser = await ChromeBrowser.connect({
    profileDir: join(tempDir, "chrome-profile"),
    timeoutMs,
    launchArguments: [
      `--proxy-server=http://127.0.0.1:${proxyPort}`,
      "--disable-quic",
      "--disable-background-networking",
      "--disable-component-update",
      "--ignore-certificate-errors",
    ],
  });
  if (!browser) throw new Error("Chrome did not start");
  try {
    const session = await ChromeServiceSession.open(browser, fixture.domain, timeoutMs, undefined, repository);
    return await session.invoke(fixture.action, fixture.args, true, timeoutMs);
  } finally {
    await browser.cdp.send("Browser.close", {}, undefined, 5_000).catch(() => {});
    browser.close();
  }
}

async function replayIOS(
  fixtures: ServiceReplayCase[],
  caCertificatePath: string,
  timeoutMs: number,
): Promise<CaseResult[]> {
  if (!process.env.OX_DEBUG_ENDPOINT) {
    throw new Error("OX_DEBUG_ENDPOINT is required for iOS replay");
  }
  const device = requiredDevice();
  const trust = Bun.spawn([
    "sim", "--device", device, "keychain", "add-root-cert", caCertificatePath,
  ], { stdout: "pipe", stderr: "pipe" });
  const [trustCode, trustOutput, trustError] = await Promise.all([
    trust.exited,
    new Response(trust.stdout).text(),
    new Response(trust.stderr).text(),
  ]);
  if (trustCode !== 0) {
    throw new Error(`failed to trust replay CA on ${device}: ${(trustError || trustOutput).trim()}`);
  }
  const runtime = createServiceRuntime("ios");
  const results: CaseResult[] = [];
  for (const fixture of fixtures) {
    const response = await runtime.invoke({
      domain: fixture.domain,
      action: fixture.action,
      args: fixture.args,
      approved: true,
      timeoutMs,
    });
    results.push(response.ok
      ? compare(fixture, { output: response.value })
      : compare(fixture, { error: response.error }));
  }
  return results;
}

function compare(
  fixture: ServiceReplayCase,
  actual: { output: unknown } | { error: string },
): CaseResult {
  const label = `${fixture.domain}:${fixture.action}:${fixture.name}`;
  if ("output" in fixture.expected) {
    if (!("output" in actual)) return { ok: false, label, detail: `expected output, got ${actual.error}` };
    return isDeepStrictEqual(actual.output, fixture.expected.output)
      ? { ok: true, label }
      : {
          ok: false,
          label,
          detail: `expected ${JSON.stringify(fixture.expected.output)}, got ${JSON.stringify(actual.output)}`,
        };
  }
  if (!("error" in actual)) return { ok: false, label, detail: `expected error containing ${JSON.stringify(fixture.expected.error)}` };
  return actual.error.includes(fixture.expected.error)
    ? { ok: true, label }
    : { ok: false, label, detail: `expected error containing ${JSON.stringify(fixture.expected.error)}, got ${actual.error}` };
}

function selectCases(fixtures: ServiceReplayCase[], selector: string | undefined): ServiceReplayCase[] {
  if (!selector) return fixtures;
  const [domain, action, name] = selector.split(":");
  return fixtures.filter((fixture) => fixture.domain === domain
    && (!action || fixture.action === action)
    && (!name || fixture.name === name));
}

function errorMatchesSelector(error: string, selector: string): boolean {
  const [domain, action] = selector.split(":");
  if (!domain || !error.includes(domain)) return false;
  if (!action) return true;
  return error.includes(`${domain}:${action}`) || error.includes(`/${action}.`);
}

function requiredDevice(): string {
  const device = process.env.OX_QA_DEVICE;
  if (!device) throw new Error("OX_QA_DEVICE is required for iOS replay");
  return device;
}

function safePathComponent(value: string): string {
  return value.replace(/[^A-Za-z0-9._-]/g, "_");
}

function assertCaseWritable(source: string, domain: string, action: string, name: string, update: boolean): void {
  const exists = readReplayCaseDefinitions(source, domain)
    .some((entry) => entry.action === action && entry.name === name);
  if (exists && !update) throw new Error(`${action}:${name} already exists; pass --update to replace it`);
}

function parseOptions(args: string[]): Options {
  if (args.includes("-h") || args.includes("--help")) usage(0);
  const command = args[0];
  if (command !== "import" && command !== "record" && command !== "replay") usage(command ? 1 : 0);
  let selector: string | undefined;
  let runtime: Runtime = "chrome";
  let proxyPort: number | undefined;
  let timeoutMs = 30_000;
  let parsedArgs: unknown;
  let profileDir: string | undefined;
  let allowLiveWrite = false;
  let update = false;
  let harPath: string | undefined;
  const requests: RecordedRequest[] = [];
  let allowPartial = false;
  let repository: string | undefined;
  let source: string | undefined;
  for (let index = 1; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--runtime") {
      const value = args[++index];
      if (value !== "chrome" && value !== "ios") throw new Error("--runtime requires chrome or ios");
      runtime = value;
    } else if (argument === "--proxy-port") {
      proxyPort = positiveInteger(args[++index], "--proxy-port");
    } else if (argument === "--timeout") {
      timeoutMs = positiveInteger(args[++index], "--timeout");
    } else if (argument === "--args") {
      const value = args[++index];
      if (value === undefined) throw new Error("--args requires JSON");
      try { parsedArgs = JSON.parse(value); }
      catch { throw new Error("--args requires valid JSON"); }
    } else if (argument === "--profile") {
      const value = args[++index];
      if (!value) throw new Error("--profile requires a directory");
      profileDir = resolve(value);
    } else if (argument === "--allow-live-write") {
      allowLiveWrite = true;
    } else if (argument === "--update") {
      update = true;
    } else if (argument === "--har") {
      const value = args[++index];
      if (!value) throw new Error("--har requires a path");
      harPath = resolve(value);
    } else if (argument === "--request") {
      const method = args[++index];
      const url = args[++index];
      if (!method || !url) throw new Error("--request requires a method and URL");
      try { new URL(url); }
      catch { throw new Error(`--request requires an absolute URL, got ${url}`); }
      requests.push({ method: method.toUpperCase(), url });
    } else if (argument === "--allow-partial") {
      allowPartial = true;
    } else if (argument === "--repository") {
      const value = args[++index];
      if (!value) throw new Error("--repository requires a local generated repository path");
      repository = resolve(value);
    } else if (argument === "--source") {
      const value = args[++index];
      if (!value) throw new Error("--source requires a service fixture directory");
      source = resolve(value);
    } else if (argument.startsWith("--")) {
      throw new Error(`unknown option ${argument}`);
    } else if (selector) {
      throw new Error(`unexpected argument ${argument}`);
    } else {
      selector = argument;
    }
  }
  if (command === "replay" && runtime === "ios" && !proxyPort) {
    throw new Error("iOS replay requires the fixed --proxy-port used in OX_SERVICE_PROXY when launching the app");
  }
  if (command === "record" && runtime !== "chrome") throw new Error("record currently uses Chrome; replay fixtures are runtime-neutral");
  if (command === "import" && runtime !== "chrome") throw new Error("import currently derives expectations in Chrome; replay fixtures are runtime-neutral");
  return {
    command,
    selector,
    runtime,
    proxyPort,
    timeoutMs,
    args: parsedArgs,
    profileDir,
    allowLiveWrite,
    update,
    harPath,
    requests,
    allowPartial,
    repository,
    source,
  };
}

function requiredRepository(options: Options): string {
  if (!options.repository) throw new Error("Chrome service tests require --repository <local-generated-repository>");
  return options.repository;
}

function requiredSource(options: Options): string {
  if (!options.source) throw new Error("service tests require --source <service-fixture-directory> or OX_SERVER_SOURCE");
  return options.source;
}

function sourceDirectory(source: string, domain: string): string {
  if (!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(domain)) throw new Error(`invalid service domain: ${domain}`);
  return join(source, domain);
}

async function sourceManifest(source: string, domain: string): Promise<ServiceManifest> {
  const value = await Bun.file(join(sourceDirectory(source, domain), "manifest.json")).json();
  if (!value || typeof value !== "object" || !Array.isArray((value as ServiceManifest).actions)) {
    throw new Error(`invalid service manifest: ${domain}`);
  }
  return value as ServiceManifest;
}

function positiveInteger(value: string | undefined, option: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0 || parsed > 65_535) throw new Error(`${option} requires an integer from 1 to 65535`);
  return parsed;
}

function usage(code: number): never {
  printUsage();
  process.exit(code);
}

function printUsage(): void {
  console.log(`Usage:
  ox service test [domain[:action[:case]]] --source directory [--proxy-port port] [--timeout ms]
  ox --repository path --runtime chrome service test --import domain:action[:case] --source directory --har capture.har [--request METHOD URL] [--args json] [--update]
  ox --repository path --runtime chrome service test --record domain:action[:case] --source directory [--args json] [--profile directory] [--allow-live-write] [--update]

iOS requires OX_QA_DEVICE and must be launched with OX_SERVICE_PROXY=http://127.0.0.1:<port> and the matching OX_DEBUG_ENDPOINT.`);
}

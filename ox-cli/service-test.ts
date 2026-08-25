import { isDeepStrictEqual } from "node:util";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createHostServiceRuntime } from "./service-runtime.ts";
import {
  auditServiceFixtures,
  type ServiceReplayCase,
} from "@openox/service-sdk/testing/replay/fixtures";
import { startReplayProxy } from "@openox/service-sdk/testing/replay/proxy";
import { fail, type CliContext } from "./lib.ts";

type Options = {
  selector?: string;
  proxyPort: number;
  timeoutMs: number;
  allowPartial: boolean;
  source: string;
};

type CaseResult = { ok: boolean; label: string; detail?: string };

export async function testService(args: string[], context: CliContext): Promise<void> {
  if (args.includes("-h") || args.includes("--help")) {
    printUsage();
    return;
  }
  await replayServices(parseOptions(args), context.host);
}

async function replayServices(options: Options, host?: string): Promise<void> {
  const audit = await auditServiceFixtures(options.source);
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
      const results = await replayOnHost(selected, proxy.caCertificatePath, options.timeoutMs, host);
      for (const result of results) {
        console.log(`${result.ok ? "PASS" : "FAIL"} ${result.label}${result.detail ? ` ${result.detail}` : ""}`);
      }
      const failed = results.filter((result) => !result.ok);
      console.log(`Service replay ${results.length - failed.length}/${results.length} passed through the Ox Host`);
      if (failed.length) process.exitCode = 1;
    } finally {
      await proxy.stop();
    }
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

async function replayOnHost(
  fixtures: ServiceReplayCase[],
  caCertificatePath: string,
  timeoutMs: number,
  host?: string,
): Promise<CaseResult[]> {
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
  const runtime = createHostServiceRuntime(host);
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

function parseOptions(args: string[]): Options {
  let selector: string | undefined;
  let proxyPort: number | undefined;
  let timeoutMs = 30_000;
  let allowPartial = false;
  let source = Bun.env.OX_SERVER_SOURCE ? resolve(Bun.env.OX_SERVER_SOURCE) : undefined;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--proxy-port") {
      proxyPort = positiveInteger(args[++index], "--proxy-port");
    } else if (argument === "--timeout") {
      timeoutMs = positiveInteger(args[++index], "--timeout");
    } else if (argument === "--allow-partial") {
      allowPartial = true;
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
  if (!proxyPort) throw new Error("service replay requires the fixed --proxy-port used in OX_SERVICE_PROXY");
  if (!source) throw new Error("service replay requires --source <service-fixture-directory> or OX_SERVER_SOURCE");
  return { selector, proxyPort, timeoutMs, allowPartial, source };
}

function requiredDevice(): string {
  const device = process.env.OX_QA_DEVICE;
  if (!device) throw new Error("OX_QA_DEVICE is required for service replay");
  return device;
}

function positiveInteger(value: string | undefined, option: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0 || parsed > 65_535) {
    throw new Error(`${option} requires an integer from 1 to 65535`);
  }
  return parsed;
}

function safePathComponent(value: string): string {
  return value.replace(/[^A-Za-z0-9._-]/g, "_");
}

function printUsage(): void {
  console.log(`Usage:
  ox [--host <ws-url>] service test [domain[:action[:case]]] --source directory --proxy-port port [--timeout ms] [--allow-partial]

Replay requires OX_QA_DEVICE and a Host launched with OX_SERVICE_PROXY=http://127.0.0.1:<port>.`);
}

import { closeSync, mkdirSync, openSync, readFileSync, statSync, unlinkSync, writeSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { runOnce } from "../../../cli/src/debug-ws.ts";
import { loadAPIKeys, type APIKeys, type LLMRegion } from "../../../../tooling/sim-bootstrap-lib.ts";
import { qaConfig, qaNumberedDevice, targetedQaDevice } from "../../../../tooling/qa-config.ts";
import { ROOT } from "../../../../tooling/lib.ts";
import { scoreResponse, validateCases, type EvalCase } from "./eval/scorer.ts";

const BUNDLE_ID = Bun.env.OX_BUNDLE_ID ?? "ai.openox.local";
const PROJECT = join(ROOT, "apps/ios/OpenOx.xcodeproj");
const SCHEME = "ios";
const REGIONS: LLMRegion[] = ["global", "china"];

type Model = {
  id: string;
  displayName: string;
  supportsTools: boolean;
};

export type MatrixClient = {
  id: string;
  displayName: string;
  credentialID: string;
  endpoint?: string;
  models: Model[];
};

type ListModelsResult = {
  ok: true;
  region: LLMRegion;
  clients: MatrixClient[];
};

export type MatrixTarget = {
  provider: string;
  client: string;
  model: string;
  region: LLMRegion;
  endpoint: string;
  credentialID: string;
};

type Options = {
  device: string;
  repository: string;
  appPath?: string;
  keysPath: string;
  output: string;
  regions: LLMRegion[];
  timeoutMs: number;
  providerConcurrency: number;
};

type CommandOptions = {
  allowFailure?: boolean;
  env?: Record<string, string | undefined>;
};

type MatrixResult = MatrixTarget & {
  passed: boolean;
  ttftMs?: number;
  totalMs?: number;
  checks: Array<{ passed: boolean; detail: string }>;
  error?: string;
};

const activeChildren = new Set<ReturnType<typeof Bun.spawn>>();
let interrupted: NodeJS.Signals | undefined;

function interrupt(signal: NodeJS.Signals): void {
  if (interrupted) return;
  interrupted = signal;
  for (const child of activeChildren) child.kill(signal);
}

process.once("SIGINT", () => interrupt("SIGINT"));
process.once("SIGTERM", () => interrupt("SIGTERM"));

function requiredValue(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function positiveInteger(value: string, flag: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) throw new Error(`${flag} must be a positive integer`);
  return parsed;
}

function usage(): string {
  return `Usage: bun run test:llm [--device ox-qa-N] [options]

Runs one scored live tool-call smoke test for every model and region represented in secrets/API_KEYS.json.

Options:
  --device <ox-qa-N>          Isolated simulator (default ox-qa-1)
  --repository <path-or-url>  Service repository served through Ox CLI
  --app <path>                   Reuse a prebuilt simulator app
  --keys <path>                  Regional API key file (default secrets/API_KEYS.json)
  --region <global|china>        Limit coverage to a region; repeat to select both
  --timeout <ms>                 Timeout per model response (default 120000)
  --provider-concurrency <n>     Concurrent models per provider (default 2)
  --output <path>                JSON coverage artifact path`;
}

function parseOptions(args: string[]): Options | undefined {
  if (args.includes("-h") || args.includes("--help")) {
    console.log(usage());
    return undefined;
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  let keysPath = join(ROOT, "secrets/API_KEYS.json");
  let appPath: string | undefined;
  let output = join(ROOT, `apps/ios/build/llm-matrix/${stamp}.json`);
  let timeoutMs = 120_000;
  let providerConcurrency = 2;
  let repository = Bun.env.OX_REPOSITORY;
  const regions: LLMRegion[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index]!;
    if (argument === "--device") index += 1;
    else if (argument === "--repository") repository = requiredValue(args, index++, argument);
    else if (argument === "--app") {
      const value = requiredValue(args, index++, argument);
      appPath = isAbsolute(value) ? value : resolve(ROOT, value);
    }
    else if (argument === "--keys") {
      const value = requiredValue(args, index++, argument);
      keysPath = isAbsolute(value) ? value : resolve(ROOT, value);
    } else if (argument === "--output") {
      const value = requiredValue(args, index++, argument);
      output = isAbsolute(value) ? value : resolve(ROOT, value);
    } else if (argument === "--region") {
      const value = requiredValue(args, index++, argument) as LLMRegion;
      if (!REGIONS.includes(value)) throw new Error("--region must be global or china");
      regions.push(value);
    } else if (argument === "--timeout") {
      timeoutMs = positiveInteger(requiredValue(args, index++, argument), argument);
    } else if (argument === "--provider-concurrency") {
      providerConcurrency = positiveInteger(requiredValue(args, index++, argument), argument);
    } else {
      throw new Error(`Unknown option ${argument}`);
    }
  }
  const selectedRegions = regions.length === 0 ? REGIONS : [...new Set(regions)];
  if (!repository) throw new Error("Pass --repository <path-or-url> or set OX_REPOSITORY");
  return {
    device: qaNumberedDevice(args, Bun.env.OX_QA_DEVICE ?? targetedQaDevice),
    repository,
    appPath,
    keysPath,
    output,
    regions: selectedRegions,
    timeoutMs,
    providerConcurrency,
  };
}

export function keyedProviders(keys: APIKeys, region: LLMRegion): string[] {
  return Object.entries(keys)
    .filter(([, regional]) => regional[region] !== undefined)
    .map(([provider]) => provider)
    .sort();
}

export function planMatrix(keys: APIKeys, region: LLMRegion, clients: MatrixClient[]): MatrixTarget[] {
  return keyedProviders(keys, region).flatMap((provider) => {
    const client = clients.find((candidate) => candidate.id === provider);
    if (!client) throw new Error(`${region} key provider ${provider} is not exposed by the running app`);
    if (!client.endpoint) throw new Error(`${region} provider ${provider} did not report its endpoint`);
    const endpoint = new URL(client.endpoint);
    if (endpoint.protocol !== "https:") throw new Error(`${region} provider ${provider} reported a non-HTTPS endpoint`);
    if (endpoint.username || endpoint.password) throw new Error(`${region} provider ${provider} reported an endpoint containing credentials`);
    endpoint.search = "";
    endpoint.hash = "";
    if (client.models.length === 0) throw new Error(`${region} provider ${provider} exposes no models`);
    const unsupported = client.models.filter((model) => !model.supportsTools).map((model) => model.id);
    if (unsupported.length > 0) throw new Error(`${region} provider ${provider} has models without tool support: ${unsupported.join(", ")}`);
    return client.models.map((model) => ({
      provider,
      client: client.id,
      model: model.id,
      region,
      endpoint: endpoint.toString(),
      credentialID: client.credentialID,
    }));
  });
}

async function command(cmd: string[], options: CommandOptions = {}): Promise<number> {
  const child = Bun.spawn({
    cmd,
    cwd: ROOT,
    env: options.env ? { ...Bun.env, ...options.env } : undefined,
    stdout: "inherit",
    stderr: "inherit",
  });
  activeChildren.add(child);
  const code = await child.exited.finally(() => activeChildren.delete(child));
  if (code !== 0 && !options.allowFailure) throw new Error(`${cmd.join(" ")} exited ${code}`);
  return code;
}

async function commandJSON<T>(cmd: string[]): Promise<T> {
  const child = Bun.spawn({ cmd, cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  activeChildren.add(child);
  const [code, output, error] = await Promise.all([
    child.exited.finally(() => activeChildren.delete(child)),
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  if (code !== 0) throw new Error(`${cmd.join(" ")} exited ${code}: ${(error || output).trim()}`);
  return JSON.parse(output) as T;
}

async function requireFreePort(port: number): Promise<void> {
  await new Promise<void>((resolvePromise, reject) => {
    const server = createServer();
    server.once("error", () => reject(new Error(`Port ${port} is already in use`)));
    server.listen(port, "127.0.0.1", () => server.close((error) => error ? reject(error) : resolvePromise()));
  });
}

async function waitForHealth(port: number): Promise<void> {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    if (interrupted) throw new Error(`Interrupted by ${interrupted}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(500) });
      if (response.ok && await response.text() === "ok") return;
    } catch {}
    await Bun.sleep(100);
  }
  throw new Error(`Registry health check timed out on port ${port}`);
}

async function request(endpoint: string, payload: Record<string, unknown>, timeoutMs: number): Promise<Record<string, unknown>> {
  return await runOnce({ ...payload, id: crypto.randomUUID() }, timeoutMs, endpoint) as Record<string, unknown>;
}

async function waitForModels(endpoint: string, region: LLMRegion): Promise<ListModelsResult> {
  const deadline = Date.now() + 60_000;
  let detail = "app is not ready";
  while (Date.now() < deadline) {
    const result = await request(endpoint, { kind: "list-models" }, 5_000);
    if (result.ok === true && result.region === region && Array.isArray(result.clients)) return result as ListModelsResult;
    detail = result.ok === true ? `reported region ${String(result.region)}` : String(result.error);
    await Bun.sleep(100);
  }
  throw new Error(`Model catalog did not become ready for ${region}: ${detail}`);
}

async function setRegion(endpoint: string, region: LLMRegion): Promise<void> {
  const deadline = Date.now() + 60_000;
  let detail = "app is not ready";
  while (Date.now() < deadline) {
    const result = await request(endpoint, { kind: "set-region", region }, 5_000);
    if (result.ok === true) return;
    detail = String(result.error);
    await Bun.sleep(100);
  }
  throw new Error(`Could not set simulator region to ${region}: ${detail}`);
}

async function waitForRegistry(endpoint: string): Promise<void> {
  const deadline = Date.now() + 60_000;
  let detail = "registry is not ready";
  while (Date.now() < deadline) {
    const result = await request(endpoint, { kind: "sync-mono-repository" }, 5_000);
    if (result.ok === true && typeof result.head === "string" && result.head && Number(result.services) > 0) return;
    detail = result.ok === true ? `head=${String(result.head)} services=${String(result.services)}` : String(result.error);
    await Bun.sleep(100);
  }
  throw new Error(`Registry did not become ready: ${detail}`);
}

async function freshChat(endpoint: string): Promise<{ id: string }> {
  const deadline = Date.now() + 60_000;
  let detail = "chat is not ready";
  while (Date.now() < deadline) {
    const result = await request(endpoint, { kind: "get-chat" }, 5_000);
    if (result.ok === true && result.data && typeof result.data === "object") {
      const data = result.data as Record<string, unknown>;
      const messages = Array.isArray(data.messages) ? data.messages : [];
      const tools = Array.isArray(data.tools) ? data.tools : [];
      if (typeof data.id === "string" && messages.length === 0 && tools.some((tool) => (tool as Record<string, unknown>)?.name === "execute")) {
        return { id: data.id };
      }
      detail = `chat id=${String(data.id)} messages=${messages.length} tools=${tools.length}`;
    } else {
      detail = String(result.error);
    }
    await Bun.sleep(100);
  }
  throw new Error(`Fresh tool-capable chat did not become ready: ${detail}`);
}

async function bootstrapRegion(keys: APIKeys, region: LLMRegion, endpoint: string): Promise<void> {
  for (const provider of keyedProviders(keys, region)) {
    const key = keys[provider]?.[region];
    if (!key) throw new Error(`Missing ${region} key for ${provider}`);
    const result = await request(endpoint, { kind: "set-key", clientId: provider, key }, 10_000);
    if (result.ok !== true) throw new Error(`${region} credential bootstrap failed for ${provider}: ${String(result.error)}`);
    console.log(`  credential ${region}:${provider} ready`);
  }
}

async function parallelMap<T, R>(values: T[], concurrency: number, transform: (value: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(values.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (next < values.length) {
      const index = next++;
      results[index] = await transform(values[index]!);
    }
  });
  await Promise.all(workers);
  return results;
}

async function runTarget(target: MatrixTarget, testCase: EvalCase, chatID: string, endpoint: string, timeoutMs: number): Promise<MatrixResult> {
  let response: Record<string, unknown>;
  try {
    response = await request(endpoint, {
      kind: "run-agent",
      sessionId: chatID,
      clientId: target.client,
      modelId: target.model,
      prompt: testCase.prompt,
    }, timeoutMs);
  } catch (error) {
    response = { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
  const score = scoreResponse(testCase, response);
  console.log(`  ${score.passed ? "PASS" : "FAIL"} ${target.region}:${target.client}:${target.model}`);
  return {
    ...target,
    passed: score.passed,
    ttftMs: typeof response.ttftMs === "number" ? response.ttftMs : undefined,
    totalMs: typeof response.totalMs === "number" ? response.totalMs : undefined,
    checks: score.checks,
    error: typeof response.error === "string" ? response.error : undefined,
  };
}

function claimDevice(device: string): () => void {
  const directory = join(tmpdir(), "ox-llm-tests");
  mkdirSync(directory, { recursive: true });
  const path = join(directory, `${device}.lock`);
  for (;;) {
    try {
      const descriptor = openSync(path, "wx", 0o600);
      writeSync(descriptor, `${process.pid}\n`);
      return () => {
        closeSync(descriptor);
        try { unlinkSync(path); } catch {}
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      if (!staleClaim(path)) throw new Error(`${device} is already claimed by another real-model test`);
      try { unlinkSync(path); } catch {}
    }
  }
}

function staleClaim(path: string): boolean {
  try {
    const pid = Number(readFileSync(path, "utf8").trim());
    if (Number.isInteger(pid) && pid > 0) {
      try {
        process.kill(pid, 0);
        return false;
      } catch (error) {
        return (error as NodeJS.ErrnoException).code === "ESRCH";
      }
    }
    return Date.now() - statSync(path).mtimeMs > 60_000;
  } catch {
    return true;
  }
}

async function runMatrix(options: Options): Promise<void> {
  const startedAt = Date.now();
  const keys = await loadAPIKeys(options.keysPath);
  const selectedRegions = options.regions.filter((region) => keyedProviders(keys, region).length > 0);
  if (selectedRegions.length === 0) throw new Error("No API keys match the selected regions");
  const corpus = validateCases(await Bun.file(join(ROOT, "apps/ios/tests/llm/cases/acceptance.json")).json());
  const testCase = corpus.find((candidate) => candidate.id === "javascript-web-search-discovery");
  if (!testCase) throw new Error("Missing javascript-web-search-discovery acceptance case");
  const config = qaConfig(options.device);
  const release = claimDevice(config.device);
  let registry: ReturnType<typeof Bun.spawn> | undefined;
  const regions: Array<{ region: LLMRegion; expected: number; results: MatrixResult[]; error?: string }> = [];
  try {
    await Promise.all([requireFreePort(config.registryPort), requireFreePort(config.debugPort)]);
    registry = Bun.spawn({
      cmd: ["bun", "apps/cli/src/ox.ts", "repository", "serve", options.repository, "--port", String(config.registryPort)],
      cwd: ROOT,
      env: Bun.env,
      stdout: "inherit",
      stderr: "inherit",
    });
    activeChildren.add(registry);
    await Promise.race([
      waitForHealth(config.registryPort),
      registry.exited.then((code) => { throw new Error(`Repository server exited ${code}`); }),
    ]);
    await command(["sim", "devices", "boot", config.device]);
    const appPath = options.appPath ?? (await commandJSON<{ app: string }>([
      "sim", "--device", config.device, "build",
      "--project", PROJECT,
      "--scheme", SCHEME,
      "--configuration", "Debug",
      "--force",
    ])).app;
    for (const region of selectedRegions) {
      try {
        await command(["sim", "--device", config.device, "uninstall", BUNDLE_ID], { allowFailure: true });
        await command(["sim", "--device", config.device, "defaults", "write", BUNDLE_ID, "app.hasCompletedOnboarding", "true", "--type", "bool"]);
        await command([
          "sim", "--device", config.device, "run", BUNDLE_ID,
          "--app", appPath,
          "--env", `OX_DEBUG_ENDPOINT=ws://127.0.0.1:${config.debugPort}`,
          "--env", `OX_SERVICES_ENDPOINT=http://127.0.0.1:${config.registryPort}/repository.git`,
          "--disable-icloud",
          "--disable-mock-llm",
        ]);
        const endpoint = `ws://127.0.0.1:${config.debugPort}`;
        await setRegion(endpoint, region);
        const catalog = await waitForModels(endpoint, region);
        await waitForRegistry(endpoint);
        await bootstrapRegion(keys, region, endpoint);
        const targets = planMatrix(keys, region, catalog.clients);
        const chat = await freshChat(endpoint);
        await waitForModels(endpoint, region);
        const grouped = Map.groupBy(targets, (target) => target.provider);
        const results = (await Promise.all([...grouped.values()].map((providerTargets) =>
          parallelMap(providerTargets, options.providerConcurrency, (target) => runTarget(target, testCase, chat.id, endpoint, options.timeoutMs))
        ))).flat();
        regions.push({ region, expected: targets.length, results });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        regions.push({ region, expected: 0, results: [], error: message });
        console.error(`FAIL ${region}: ${message}`);
      }
    }
  } finally {
    if (registry) {
      registry.kill("SIGTERM");
      await registry.exited;
      activeChildren.delete(registry);
    }
    await command(["sim", "--device", config.device, "uninstall", BUNDLE_ID], { allowFailure: true });
    await command(["sim", "devices", "shutdown", config.device], { allowFailure: true });
    release();
  }
  const expected = regions.reduce((total, region) => total + region.expected, 0);
  const completed = regions.reduce((total, region) => total + region.results.length, 0);
  const passed = regions.length === selectedRegions.length
    && regions.every((region) => !region.error && region.results.length === region.expected && region.results.every((result) => result.passed));
  const artifact = {
    version: 1,
    mode: "keyed-model-region-matrix",
    startedAt: new Date(startedAt).toISOString(),
    finishedAt: new Date().toISOString(),
    elapsedMs: Date.now() - startedAt,
    device: options.device,
    case: testCase.id,
    selectedRegions,
    expected,
    completed,
    regions,
    passed,
  };
  await mkdir(dirname(options.output), { recursive: true });
  await Bun.write(options.output, `${JSON.stringify(artifact, null, 2)}\n`);
  console.log(`\n${passed ? "PASS" : "FAIL"} keyed real-model matrix ${completed}/${expected}`);
  console.log(options.output);
  if (!passed) process.exitCode = 1;
}

if (import.meta.main) {
  try {
    const options = parseOptions(Bun.argv.slice(2));
    if (options) await runMatrix(options);
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}

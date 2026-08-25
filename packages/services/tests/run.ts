import { closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, statSync, unlinkSync, writeSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { runOnce } from "../../../apps/cli/src/debug-ws.ts";
import { qaConfig, qaNumberedDevice, targetedQaDevice } from "../../../tooling/qa-config.ts";
import { ROOT } from "../../../tooling/lib.ts";

const BUNDLE_ID = Bun.env.OX_BUNDLE_ID ?? "ai.openox.local";
const PROJECT = join(ROOT, "apps/ios/OpenOx.xcodeproj");
const SCHEME = "ios";

type Options = {
  device: string;
  selector?: string;
  repository: string;
};

type CommandOptions = {
  allowFailure?: boolean;
  env?: Record<string, string | undefined>;
  cwd?: string;
};

type SimInventory = {
  devices?: Record<string, Array<{ name?: unknown }>>;
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

async function command(cmd: string[], options: CommandOptions = {}): Promise<number> {
  const child = Bun.spawn({
    cmd,
    cwd: options.cwd ?? ROOT,
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

async function ensureDevice(device: string): Promise<void> {
  const inventory = await commandJSON<SimInventory>(["sim", "devices"]);
  const simulators = Object.values(inventory.devices ?? {}).flat() as Array<{ name?: unknown }>;
  if (simulators.some((candidate) => candidate.name === device)) return;
  const source = device === targetedQaDevice ? undefined : targetedQaDevice;
  if (!source || !simulators.some((candidate) => candidate.name === source)) {
    throw new Error(`Cannot create ${device}: no QA simulator template is available`);
  }
  await command(["sim", "devices", "clone", source, device]);
}

async function requireFreePort(port: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const server = createServer();
    server.once("error", () => reject(new Error(`Port ${port} is already in use`)));
    server.listen(port, "127.0.0.1", () => server.close((error) => error ? reject(error) : resolve()));
  });
}

async function waitForHttp(port: number): Promise<void> {
  const deadline = performance.now() + 60_000;
  while (performance.now() < deadline) {
    if (interrupted) throw new Error(`Interrupted by ${interrupted}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(500) });
      if (response.ok && await response.text() === "ok") return;
    } catch {}
    await Bun.sleep(100);
  }
  throw new Error(`Registry health check timed out on port ${port}`);
}

async function waitForRegistry(endpoint: string, expectedDomain?: string): Promise<void> {
  const deadline = performance.now() + 60_000;
  let detail = "registry is not ready";
  while (performance.now() < deadline) {
    if (interrupted) throw new Error(`Interrupted by ${interrupted}`);
    const result = await runOnce({ kind: "sync-mono-repository", id: crypto.randomUUID() }, 5_000, endpoint);
    if (result.ok && typeof result.head === "string" && result.head && Number(result.services) > 0) {
      if (!expectedDomain) return;
      const status = await runOnce({ kind: "list-services", id: crypto.randomUUID() }, 5_000, endpoint);
      const services = status.ok && Array.isArray(status.services) ? status.services : [];
      if (services.some((service) => service?.domain === expectedDomain)) return;
    }
    detail = result.ok ? `head=${String(result.head)} services=${String(result.services)}` : result.error;
    await Bun.sleep(100);
  }
  throw new Error(`Registry did not become ready through ${endpoint}: ${detail}`);
}

function parseOptions(args: string[]): Options {
  if (args.includes("-h") || args.includes("--help")) {
    console.log("Usage: bun run test:services [domain[:action[:case]]] --repository <service-repository> [--device ox-qa-N]");
    process.exit(0);
  }
  let selector: string | undefined;
  let repository: string | undefined;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--device") {
      if (!args[++index]) throw new Error("--device requires ox-qa-N");
    } else if (argument === "--repository") {
      const value = args[++index];
      if (!value) throw new Error("--repository requires a local service repository");
      repository = resolve(value);
    } else if (argument.startsWith("--")) {
      throw new Error(`Unknown option ${argument}`);
    } else if (selector) {
      throw new Error(`Unexpected argument ${argument}`);
    } else {
      selector = argument;
    }
  }
  const device = qaNumberedDevice(args, Bun.env.OX_QA_DEVICE ?? targetedQaDevice);
  repository ??= Bun.env.OX_SERVER_ROOT ? resolve(Bun.env.OX_SERVER_ROOT) : undefined;
  if (!repository) throw new Error("Pass --repository <service-repository> or set OX_SERVER_ROOT");
  return { device, selector, repository };
}

function claimDevice(device: string): () => void {
  const directory = join(tmpdir(), "ox-service-tests");
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
      if (!staleClaim(path)) throw new Error(`${device} is already claimed by another service test`);
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

async function printDiagnostics(device: string): Promise<void> {
  await command(["sim", "--device", device, "logs"], { allowFailure: true });
}

const options = parseOptions(Bun.argv.slice(2));
const config = qaConfig(options.device);
const release = claimDevice(config.device);
let registry: ReturnType<typeof Bun.spawn> | undefined;
let failed = false;
const serverTemporary = mkdtempSync(join(tmpdir(), "openox-service-replay-"));
const generatedRepository = join(serverTemporary, "repository");

try {
  await Promise.all([
    requireFreePort(config.serviceProxyPort),
    requireFreePort(config.registryPort),
    requireFreePort(config.debugPort),
  ]);
  await ensureDevice(config.device);
  console.log(`Service replay ${config.device}: proxy ${config.serviceProxyPort}, repository ${config.registryPort}, debug ${config.debugPort}`);
  const builtinRepository = resolve(ROOT, "repositories/builtin");
  if (options.repository === builtinRepository) {
    await command(["bun", "packages/services/export.ts", "--output", generatedRepository, "--web-only"]);
  } else {
    await command(["bun", "run", "export", "--output", generatedRepository], { cwd: options.repository });
  }
  registry = Bun.spawn({
    cmd: ["bun", "apps/cli/src/ox.ts", "repository", "serve", generatedRepository, "--port", String(config.registryPort)],
    cwd: ROOT,
    env: Bun.env,
    stdout: "inherit",
    stderr: "ignore",
  });
  activeChildren.add(registry);
  await Promise.race([
    waitForHttp(config.registryPort),
    registry.exited.then((code) => { throw new Error(`repository server exited ${code}`); }),
  ]);
  await command(["sim", "devices", "boot", config.device]);
  await command(["sim", "--device", config.device, "uninstall", BUNDLE_ID], { allowFailure: true });
  await command([
    "sim", "--device", config.device,
    "defaults", "write", BUNDLE_ID,
    "app.hasCompletedOnboarding", "true", "--type", "bool",
  ]);
  await command([
    "sim", "--device", config.device,
    "run", BUNDLE_ID,
    "--project", PROJECT,
    "--scheme", SCHEME,
    "--configuration", "Debug",
    "--force",
    "--env", `OX_DEBUG_ENDPOINT=ws://127.0.0.1:${config.debugPort}`,
    "--env", `OX_SERVICES_ENDPOINT=http://127.0.0.1:${config.registryPort}/repository.git`,
    "--env", `OX_SERVICE_PROXY=http://127.0.0.1:${config.serviceProxyPort}`,
    "--disable-icloud",
  ]);
  const debugEndpoint = `ws://127.0.0.1:${config.debugPort}`;
  await waitForRegistry(debugEndpoint, options.selector?.split(":")[0]);
  const environment = {
    OX_QA_DEVICE: config.device,
    OX_DEBUG_ENDPOINT: debugEndpoint,
    OX_SERVER_SOURCE: join(options.repository, "web"),
  };
  await command([
    "bun", "apps/cli/src/ox.ts",
    "service", "test",
    ...(options.selector ? [options.selector] : []),
    "--proxy-port", String(config.serviceProxyPort),
    "--allow-partial",
  ], { env: environment });
} catch (error) {
  failed = true;
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = interrupted === "SIGINT" ? 130 : interrupted === "SIGTERM" ? 143 : 1;
} finally {
  if (failed) await printDiagnostics(config.device);
  if (registry) {
    registry.kill("SIGTERM");
    await registry.exited;
    activeChildren.delete(registry);
  }
  await command(["sim", "--device", config.device, "uninstall", BUNDLE_ID], { allowFailure: true });
  await command(["sim", "devices", "shutdown", config.device], { allowFailure: true });
  rmSync(serverTemporary, { recursive: true, force: true });
  release();
}

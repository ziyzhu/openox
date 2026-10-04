import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { callHost } from "../../apps/cli/src/host-rpc.ts";
import { ROOT, killChildren, run } from "../lib.ts";
import { qaCommand } from "./qa-config.ts";
import { claimSimulator, requireSimulator, requireFreePort } from "./simulator.ts";

const BUNDLE_ID = Bun.env.OX_BUNDLE_ID ?? "ai.openox.local";
const PROJECT = join(ROOT, "apps/ios/Ox.xcodeproj");
const SCHEME = "ios";

let interrupted: NodeJS.Signals | undefined;

function interrupt(signal: NodeJS.Signals): void {
  if (interrupted) return;
  interrupted = signal;
  killChildren(signal);
}

process.once("SIGINT", () => interrupt("SIGINT"));
process.once("SIGTERM", () => interrupt("SIGTERM"));

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

async function waitForServices(endpoint: string, expectedDomain?: string): Promise<void> {
  const deadline = performance.now() + 60_000;
  let detail = "services are not ready";
  while (performance.now() < deadline) {
    if (interrupted) throw new Error(`Interrupted by ${interrupted}`);
    try {
      const result = await callHost("services.sync", {}, 5_000, endpoint);
      if (typeof result.head === "string" && result.head && Number(result.services) > 0) {
        if (!expectedDomain) return;
        const status = await callHost("services.list", {}, 30_000, endpoint);
        const services = Array.isArray(status.services) ? status.services : [];
        if (services.some((service) => service?.domain === expectedDomain)) return;
        detail = `service ${expectedDomain} is not listed`;
      } else detail = `head=${String(result.head)} services=${String(result.services)}`;
    } catch (error) { detail = (error as Error).message; }
    await Bun.sleep(100);
  }
  throw new Error(`Services did not become ready through ${endpoint}: ${detail}`);
}

const config = qaCommand({
  usage: "Usage: bun run test:services [domain[:action[:case]]] --device ox-N [--repository <repository>] [--reset]\nReserve the device first. --reset uninstalls the app and deletes its local data before replay.",
  options: { repository: { type: "string" }, reset: { type: "boolean" } },
  positionals: 1,
});
if (!config.values.device) throw new Error("Pass --device ox-N explicitly after reserving the simulator");
const selector = config.positionals[0];
const repositoryRoot = config.values.repository ?? Bun.env.OX_SERVER_ROOT;
const repository = repositoryRoot ? resolve(repositoryRoot) : undefined;
const release = claimSimulator(config.device);
let registry: ReturnType<typeof Bun.spawn> | undefined;
let failed = false;
let serverTemporary: string | undefined;
let bootedByReplay = false;
let launchAttempted = false;

try {
  await Promise.all([
    requireFreePort(config.serviceProxyPort),
    ...(repository ? [requireFreePort(config.registryPort)] : []),
    requireFreePort(config.debugPort),
  ]);
  const wasBooted = await requireSimulator(config.device);
  console.log(`Service replay ${config.device}: proxy ${config.serviceProxyPort}, services ${repository ? `repository ${config.registryPort}` : "bundled"}, debug ${config.debugPort}`);
  if (repository) {
    serverTemporary = mkdtempSync(join(tmpdir(), "openox-service-replay-"));
    const generatedRepository = join(serverTemporary, "repository");
    if (repository === resolve(ROOT, "repositories/builtin")) {
      await run(["bun", "packages/services/export.ts", "--output", generatedRepository, "--web-only"]);
    } else {
      await run(["bun", "run", "export", "--output", generatedRepository], { cwd: repository });
    }
    registry = Bun.spawn({
      cmd: ["bun", "apps/cli/src/ox.ts", "--repository", generatedRepository, "repository", "serve", "--port", String(config.registryPort)],
      cwd: ROOT,
      env: Bun.env,
      stdout: "inherit",
      stderr: "ignore",
    });
    await Promise.race([
      waitForHttp(config.registryPort),
      registry.exited.then((code) => { throw new Error(`repository server exited ${code}`); }),
    ]);
  }
  if (!wasBooted) {
    await run(["sim", "devices", "boot", config.device]);
    bootedByReplay = true;
  }
  if (config.values.reset) await run(["sim", "--device", config.device, "uninstall", BUNDLE_ID], { allowFailure: true });
  await run([
    "sim", "--device", config.device,
    "defaults", "write", BUNDLE_ID,
    "app.hasCompletedOnboarding", "true", "--type", "bool",
  ]);
  launchAttempted = true;
  await run([
    "sim", "--device", config.device,
    "run", BUNDLE_ID,
    "--project", PROJECT,
    "--scheme", SCHEME,
    "--configuration", "Debug",
    "--force",
    "--env", `OX_DEBUG_ENDPOINT=${config.debugEndpoint}`,
    ...(repository ? ["--env", `OX_SERVICES_ENDPOINT=http://127.0.0.1:${config.registryPort}/repository.git`] : []),
    "--env", `OX_SERVICE_PROXY=http://127.0.0.1:${config.serviceProxyPort}`,
    "--disable-icloud",
  ]);
  await waitForServices(config.debugEndpoint, selector?.split(":")[0]);
  const environment = {
    OX_QA_DEVICE: config.device,
    OX_DEBUG_ENDPOINT: config.debugEndpoint,
  };
  await run([
    "bun", "apps/cli/src/ox.ts",
    "--repository", repository ?? resolve(ROOT, "repositories/builtin"),
    "repository", "test",
    ...(selector ? [selector] : []),
    "--proxy-port", String(config.serviceProxyPort),
    "--allow-partial",
  ], { env: environment });
} catch (error) {
  failed = true;
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = interrupted === "SIGINT" ? 130 : interrupted === "SIGTERM" ? 143 : 1;
} finally {
  try {
    if (failed && launchAttempted) await run(["sim", "--device", config.device, "logs"], { allowFailure: true });
    if (registry) {
      registry.kill("SIGTERM");
      await registry.exited;
    }
    if (bootedByReplay) await run(["sim", "devices", "shutdown", config.device], { allowFailure: true });
    if (serverTemporary) rmSync(serverTemporary, { recursive: true, force: true });
  } finally {
    release();
  }
}

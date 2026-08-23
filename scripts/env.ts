import { createServer } from "node:net";
import { join } from "node:path";
import { ROOT } from "./lib.ts";
import { envDevice, qaConfig } from "./qa-config.ts";

const BUNDLE_ID = Bun.env.OX_BUNDLE_ID ?? "ai.openox.local";
const PROJECT = join(ROOT, "ios/ios.xcodeproj");
const SCHEME = "ios";

async function command(cmd: string[], allowFailure = false): Promise<number> {
  const child = Bun.spawn({ cmd, cwd: ROOT, stdout: "inherit", stderr: "inherit" });
  const code = await child.exited;
  if (code !== 0 && !allowFailure) throw new Error(`${cmd.join(" ")} exited ${code}`);
  return code;
}

async function requireFreePort(port: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const probe = createServer();
    probe.once("error", () => reject(new Error(`Port ${port} is already in use`)));
    probe.listen(port, "127.0.0.1", () => probe.close((error) => error ? reject(error) : resolve()));
  });
}

async function waitForHealth(port: number): Promise<void> {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(500) });
      if (response.ok && await response.text() === "ok") return;
    } catch {}
    await Bun.sleep(100);
  }
  throw new Error(`Registry health check timed out on port ${port}`);
}

function waitForSignal(onSignal: () => void): Promise<void> {
  return new Promise((resolve) => {
    const stop = () => {
      onSignal();
      resolve();
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
}

function repositoryOrigin(args: string[]): string {
  const index = args.indexOf("--repository");
  const origin = index >= 0 ? args[index + 1] : Bun.env.OX_REPOSITORY;
  if (!origin) throw new Error("Pass --repository <path-or-url> or set OX_REPOSITORY");
  return origin;
}

const args = Bun.argv.slice(2);
const device = envDevice(args, Bun.env.OX_QA_DEVICE);
const repository = repositoryOrigin(args);
const config = qaConfig(device);
await requireFreePort(config.registryPort);
await requireFreePort(config.debugPort);

console.log(`Environment ${config.device}: repository ${config.registryPort}, debug ${config.debugPort}`);
const repositoryServer = Bun.spawn({
  cmd: ["bun", "ox-cli/ox.ts", "repository", "serve", repository, "--port", String(config.registryPort)],
  cwd: ROOT,
  env: Bun.env,
  stdout: "inherit",
  stderr: "inherit",
});
let stopping = false;
const repositoryServerExit = repositoryServer.exited.then((code) => {
  if (!stopping) throw new Error(`Repository server exited ${code}`);
});

try {
  await Promise.race([waitForHealth(config.registryPort), repositoryServerExit]);
  await Bun.sleep(100);
  if (repositoryServer.exitCode !== null) throw new Error(`Repository server exited ${repositoryServer.exitCode}`);
  await command(["sim", "devices", "boot", config.device]);
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
    "--env", `OX_DEBUG_ENDPOINT=ws://127.0.0.1:${config.debugPort}`,
    "--env", `OX_SERVICES_ENDPOINT=http://127.0.0.1:${config.registryPort}/repository.git`,
    "--disable-icloud",
  ]);
  console.log(`READY ${config.device}`);
  console.log(`OX_DEBUG_ENDPOINT=ws://127.0.0.1:${config.debugPort} bun run debug dev logs --level error`);
  console.log("Press Ctrl-C to stop and release the slot");
  await Promise.race([waitForSignal(() => { stopping = true; }), repositoryServerExit]);
} finally {
  stopping = true;
  repositoryServer.kill();
  await repositoryServer.exited;
  await command(["sim", "devices", "shutdown", config.device], true);
  console.log(`released environment ${config.device}`);
}

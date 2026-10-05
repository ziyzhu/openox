import { mkdtemp, mkdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import { ROOT, killChildren, run } from "../lib.ts";
import { qaCommand } from "./qa-config.ts";
import { claimSimulator, requireSimulator } from "./simulator.ts";

const config = qaCommand({
  usage: `Usage: ./scripts/ios-ci.sh --device ox-N [--host <ws-url>] [--bundle <id>] [--output <directory>]
Reserve the device and prepare the common QA state first. Host connections must already be enabled.
Builds/launches the app and runs a temporary Mock chat. Never resets app data or changes credentials/settings.
Evidence stays outside the repository.`,
  options: {
    host: { type: "string" }, bundle: { type: "string" }, output: { type: "string" },
  },
});
if (!config.values.device) throw new Error("Pass --device ox-N explicitly after reserving the simulator");
if (!Bun.which("sim")) throw new Error("Install sim and configure Xcode before running iOS CI");
const endpoint = config.values.host ?? config.debugEndpoint;
const url = new URL(endpoint);
if (!["ws:", "wss:"].includes(url.protocol) || Number(url.port) !== config.debugPort) {
  throw new Error(`Use this simulator's Host on port ${config.debugPort}; do not target another device`);
}
const localConfig = await Bun.file(join(ROOT, "apps/ios/Local.xcconfig")).text().catch(() => "");
const bundle = config.values.bundle ?? Bun.env.OX_BUNDLE_ID
  ?? /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(localConfig)?.[1] ?? "ai.openox.local";
let interrupted: NodeJS.Signals | undefined;
function interrupt(signal: NodeJS.Signals) {
  interrupted = signal;
  killChildren(signal);
}
process.once("SIGINT", () => interrupt("SIGINT"));
process.once("SIGTERM", () => interrupt("SIGTERM"));

async function evidenceDirectory(): Promise<string> {
  const directory = resolve(config.values.output ?? tmpdir());
  await mkdir(directory, { recursive: true });
  const parent = await realpath(directory);
  const fromRoot = relative(await realpath(ROOT), parent);
  if (!fromRoot || (!fromRoot.startsWith("../") && !isAbsolute(fromRoot))) {
    throw new Error("Store iOS evidence outside the repository");
  }
  return mkdtemp(join(parent, "openox-ios-ci-"));
}

async function ox(...args: string[]): Promise<any> {
  const { stdout } = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, ...args, "--json"], { capture: true });
  return JSON.parse(stdout);
}

async function waitForHost(): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (interrupted) throw new Error(`Interrupted by ${interrupted}`);
    try { await ox("host", "describe", "--timeout", "1000"); return; } catch {}
    await Bun.sleep(200);
  }
  throw new Error(`Host unavailable at ${endpoint}; enable Host connections in Ox and pass --host for VPN ingress`);
}

const release = claimSimulator(config.device);
let bootedByCi = false;
let launched = false;
let chatId: string | undefined;
let previousChat: string | undefined;
let evidence: string | undefined;
let completed = false;
try {
  const wasBooted = await requireSimulator(config.device);
  evidence = await evidenceDirectory();
  console.log(`iOS CI ${config.device}; evidence: ${evidence}`);
  if (!wasBooted) {
    await run(["sim", "devices", "boot", config.device]);
    bootedByCi = true;
  }
  launched = true;
  const build = await run([
    "sim", "--device", config.device, "run", bundle,
    "--project", "apps/ios/Ox.xcodeproj", "--scheme", "ios", "--configuration", "Debug", "--force",
    "--env", `OX_DEBUG_ENDPOINT=${endpoint}`,
  ], { capture: true });
  await writeFile(join(evidence, "build.json"), build.stdout, { mode: 0o600 });
  await waitForHost();
  const rows = await ox("chat", "list", "--active") as Array<{ id: string }>;
  previousChat = rows[0]?.id;
  const created = await ox("chat", "new", "--temporary", "--provider", "mock", "--model", "mock");
  if (typeof created.chatId !== "string") throw new Error("Host did not return a temporary chat ID");
  chatId = created.chatId;
  const outcome = await ox("--chat", chatId!, "chat", "send", "2", "--timeout", "60000");
  if (outcome.outcome !== "completed" || outcome.text !== "Sorry that took a moment.") {
    throw new Error(`Mock chat did not complete as expected: ${JSON.stringify(outcome)}`);
  }
  const snapshot = await ox("--chat", chatId!, "chat", "inspect", "--full");
  if (snapshot.id !== chatId || snapshot.model?.id !== "mock" || snapshot.isBusy
      || !JSON.stringify(snapshot.messages).includes(outcome.text)) {
    throw new Error("Completed Mock chat snapshot is missing its reply");
  }
  await writeFile(join(evidence, "chat.json"), JSON.stringify({ outcome, snapshot }, null, 2), { mode: 0o600 });
  await run(["sim", "--device", config.device, "wait", "--id", "chat.message.agent", "--timeout", "10000"]);
  await run(["sim", "--device", config.device, "screenshot", "--out", join(evidence, "chat.png")]);
  completed = true;
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = interrupted === "SIGINT" ? 130 : interrupted === "SIGTERM" ? 143 : 1;
} finally {
  try {
    if (chatId) {
      await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, "--chat", chatId, "chat", "stop", "--timeout", "5000"], { allowFailure: true });
      const restore = previousChat
        ? ["--chat", previousChat, "chat", "open"] : ["chat", "new", "--temporary"];
      const result = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, ...restore, "--timeout", "5000"], { allowFailure: true });
      if (result.code !== 0) {
        console.error("Could not restore the previous chat; restore it in Ox before releasing the simulator");
        process.exitCode ||= 1;
      }
    }
    if (launched && process.exitCode) {
      const logs = await run(["sim", "--device", config.device, "logs"], { capture: true, allowFailure: true });
      if (evidence) await writeFile(join(evidence, "failure-logs.json"), logs.stdout + logs.stderr, { mode: 0o600 });
    }
    if (bootedByCi) await run(["sim", "devices", "shutdown", config.device], { allowFailure: true });
  } finally { release(); }
}
if (completed && !process.exitCode) console.log(`PASS iOS build, launch, Mock reply, and visible assistant message (${config.device})`);

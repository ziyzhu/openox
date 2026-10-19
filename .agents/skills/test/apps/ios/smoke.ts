import { mkdtemp, mkdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import { ROOT, killChildren, run } from "../../../../lib.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../setup/scripts/simulator.ts";
import { iosTarget } from "../../../setup/scripts/ios.ts";

const config = qaCommand({
  usage: `Usage: bun run ci:ios --device ox-N [--host <ws-url>] [--bundle <id>] [--app <Ox.app>] [--output <directory>] [--loopback]
Reserve the device and prepare the common QA state first. Host connections must already be enabled.
Builds/launches the app and runs a temporary Mock conversation. --app reuses a verified build instead of building.
Never resets app data or changes credentials/settings.
--loopback opts this Debug Simulator launch into localhost Host access; other launches remain Tailscale-only.
Evidence stays outside the repository.`,
  options: {
    host: { type: "string" }, bundle: { type: "string" }, app: { type: "string" }, output: { type: "string" }, loopback: { type: "boolean" },
  },
});
if (!config.values.device) throw new Error("Pass --device ox-N explicitly after reserving the simulator");
if (!Bun.which("idb") || !config.values.app && !Bun.which("xcodebuild")) throw new Error("Install idb and configure Xcode before running iOS CI");
const ios = iosTarget(config.device);
const endpoint = config.values.host ?? config.debugEndpoint;
const url = new URL(endpoint);
if (!["ws:", "wss:"].includes(url.protocol) || Number(url.port) !== config.debugPort) {
  throw new Error(`Use this simulator's Host on port ${config.debugPort}; do not target another device`);
}
if (config.values.loopback && (url.protocol !== "ws:" || url.hostname !== "127.0.0.1")) {
  throw new Error("Debug Simulator loopback requires ws://127.0.0.1 on this simulator's assigned port");
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
  throw new Error(`Host unavailable at ${endpoint}; enable Host connections and use --loopback for Debug Simulator localhost or --host for Tailscale ingress`);
}

const release = claimSimulator(config.device);
let bootedByCi = false;
let launched = false;
let conversationId: string | undefined;
let previousConversation: string | undefined;
let evidence: string | undefined;
let completed = false;
try {
  const wasBooted = await requireSimulator(config.device);
  evidence = await evidenceDirectory();
  console.log(`iOS CI ${config.device}; evidence: ${evidence}`);
  if (!wasBooted) {
    await ios.boot();
    bootedByCi = true;
  }
  launched = true;
  const app = config.values.app ? resolve(config.values.app)
    : await ios.build(join(evidence, "DerivedData"), join(evidence, "build.log"));
  const launch = await ios.launch(bundle, app, {
    OX_DEBUG_ENDPOINT: endpoint, OX_HOST_LOOPBACK: config.values.loopback ? "1" : "0",
  });
  await writeFile(join(evidence, "launch.json"), JSON.stringify(launch), { mode: 0o600 });
  await waitForHost();
  const rows = await ox("conversation", "list", "--active") as Array<{ id: string }>;
  previousConversation = rows[0]?.id;
  const created = await ox("conversation", "new", "--temporary", "--provider", "mock", "--model", "mock");
  if (typeof created.conversationId !== "string" || !created.conversationId || created.temporary !== true || created.model !== "mock:mock") {
    throw new Error("Host did not return the requested temporary Mock conversation");
  }
  conversationId = created.conversationId;
  const outcome = await ox("--conversation", conversationId!, "conversation", "send", "2", "--timeout", "60000");
  if (outcome.outcome !== "completed" || outcome.text !== "Sorry that took a moment.") {
    throw new Error(`Mock conversation did not complete as expected: ${JSON.stringify(outcome)}`);
  }
  const snapshot = await ox("--conversation", conversationId!, "conversation", "inspect", "--full");
  if (snapshot.id !== conversationId || snapshot.model?.id !== "mock" || snapshot.isBusy
      || !JSON.stringify(snapshot.messages).includes(outcome.text)) {
    throw new Error("Completed Mock conversation snapshot is missing its reply");
  }
  await writeFile(join(evidence, "conversation.json"), JSON.stringify({ outcome, snapshot }, null, 2), { mode: 0o600 });
  await ios.wait({ id: "conversation.message.agent" }, { timeout: 10_000 });
  await ios.screenshot(join(evidence, "conversation.png"));
  completed = true;
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = interrupted === "SIGINT" ? 130 : interrupted === "SIGTERM" ? 143 : 1;
} finally {
  try {
    if (conversationId) {
      await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, "--conversation", conversationId, "conversation", "stop", "--timeout", "5000"], { allowFailure: true });
      const restore = previousConversation
        ? ["--conversation", previousConversation, "conversation", "open"] : ["conversation", "new", "--temporary"];
      const result = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, ...restore, "--timeout", "5000"], { allowFailure: true });
      if (result.code !== 0) {
        console.error("Could not restore the previous conversation; restore it in Ox before releasing the simulator");
        process.exitCode ||= 1;
      }
    }
    if (launched && process.exitCode) {
      const logs = await ios.logs();
      if (evidence) await writeFile(join(evidence, "failure-logs.json"), logs.stdout + logs.stderr, { mode: 0o600 });
    }
    if (bootedByCi) await ios.shutdown();
  } finally { release(); }
}
if (completed && !process.exitCode) console.log(`PASS iOS ${config.values.app ? "prebuilt app" : "build"}, launch, Mock reply, and visible assistant message (${config.device})`);

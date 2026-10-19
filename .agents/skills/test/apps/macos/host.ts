import { parseArgs } from "node:util";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { requireFreePort } from "../../../setup/scripts/simulator.ts";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: { app: { type: "string" }, output: { type: "string" } },
  strict: true,
});
if (!values.app) throw new Error("Usage: bun .agents/skills/test/apps/macos/host.ts --app <Debug OxHost.app> [--output <directory>]");
const app = resolve(values.app);
const metadata = await run(["plutil", "-convert", "json", "-o", "-", join(app, "Contents/Info.plist")], { capture: true });
const info = JSON.parse(metadata.stdout);
if (info.CFBundleIdentifier !== "ai.openox.host.local") throw new Error("Use the development Mac Host bundle");
for (const key of ["OXAppGroupIdentifier", "OXICloudContainerIdentifier", "OXKeychainService", "OXWebsiteDataNamespace", "OXAgentSkillTypeIdentifier", "OXConversationTypeIdentifier", "OXServiceTypeIdentifier"]) {
  if (typeof info[key] !== "string" || !info[key]) throw new Error(`Missing Host configuration: ${key}`);
}
const existing = await run(["pgrep", "-x", "OxHost"], { capture: true, allowFailure: true });
if (existing.code === 0) throw new Error("Stop existing Mac Hosts before running sandbox-mutating verification");
const directory = resolve(values.output ?? tmpdir());
if (directory === ROOT || directory.startsWith(`${ROOT}/`)) throw new Error("Keep evidence outside the repository");
await mkdir(directory, { recursive: true });
const evidence = await mkdtemp(join(directory, "ox-macos-host-"));
const endpoint = "ws://127.0.0.1:19876";
await requireFreePort(19876);
function launchProcess(flag: string) {
  return Bun.spawn([join(app, "Contents/MacOS/OxHost"), flag], {
    env: { ...Bun.env, OX_HOST_ENDPOINT: endpoint, OX_HOST_LOOPBACK: "1" },
    stdout: "pipe", stderr: "pipe",
  });
}

let process: ReturnType<typeof launchProcess> | undefined;
let capture: Promise<string> | undefined;
let launches = 0;

async function ox(...args: string[]): Promise<any> {
  const result = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, ...args, "--json"], { capture: true });
  return JSON.parse(result.stdout);
}

async function start(flag = "--allow-connections") {
  process = launchProcess(flag);
  capture = Promise.all([new Response(process.stdout).text(), new Response(process.stderr).text()]).then(parts => parts.join("\n"));
  launches += 1;
  if (flag !== "--allow-connections") return;
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (process.exitCode !== null) throw new Error(`Host exited during startup: ${await capture}`);
    try { await ox("host", "describe", "--timeout", "1000"); return; } catch {}
    await Bun.sleep(200);
  }
  throw new Error("Mac Host did not become reachable");
}

async function waitForBusy(conversation: string) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if ((await ox("--conversation", conversation, "conversation", "inspect")).isBusy) return;
    await Bun.sleep(100);
  }
  throw new Error("Run fixture did not become busy");
}

async function stop() {
  if (!process) return;
  const current = process;
  current.kill("SIGTERM");
  const code = await Promise.race([current.exited, Bun.sleep(15_000).then(() => null)]);
  if (code === null) {
    current.kill("SIGKILL");
    await current.exited;
    throw new Error("Mac Host did not terminate gracefully");
  }
  await writeFile(join(evidence, `process-${launches}.log`), await capture ?? "");
  process = undefined;
  if (code !== 0) throw new Error(`Mac Host exited with ${code}`);
}

try {
  await start();
  const description = await ox("host", "describe");
  if (description.methods.some((method: string) => method.includes("composer"))) throw new Error("Headless Host advertises composer methods");
  await writeFile(join(evidence, "description.json"), JSON.stringify(description, null, 2));
  const browserAccepted = await new Promise<boolean>((resolve) => {
    const Socket = WebSocket as unknown as new (url: string, options: Bun.WebSocketOptions) => WebSocket;
    const socket = new Socket(endpoint, { headers: { Origin: "https://example.invalid" } });
    const timer = setTimeout(() => { socket.close(); resolve(false); }, 3000);
    const finish = (accepted: boolean) => { clearTimeout(timer); socket.close(); resolve(accepted); };
    socket.addEventListener("open", () => finish(true));
    socket.addEventListener("error", () => finish(false));
    socket.addEventListener("close", () => finish(false));
  });
  if (browserAccepted) throw new Error("Host accepted a browser Origin");
  await ox("conversation", "new", "--provider", "mock", "--model", "mock");
  const outcome = await ox("conversation", "send", "2", "--timeout", "60000");
  if (outcome.outcome !== "completed" || outcome.text !== "Sorry that took a moment.") throw new Error("Mock conversation did not complete");
  const conversation = outcome.conversationId as string;
  const script = await ox("--conversation", conversation, "vm", "eval", "--script", "return 2 + 2;");
  if (script.value !== 4) throw new Error("Native JavaScript execution failed");
  const pending = run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, "--conversation", conversation, "conversation", "send", "2", "--timeout", "60000", "--json"], { capture: true, allowFailure: true });
  await waitForBusy(conversation);
  await ox("--conversation", conversation, "conversation", "stop");
  const cancelled = await pending;
  if (cancelled.code !== 1 || !cancelled.stderr.includes("send cancelled")) throw new Error("Conversation cancellation failed");
  await stop();
  await start();
  await ox("--conversation", conversation, "conversation", "open");
  const snapshot = await ox("--conversation", conversation, "conversation", "inspect", "--full");
  if (snapshot.id !== conversation || snapshot.isBusy || !JSON.stringify(snapshot.messages).includes("Sorry that took a moment.")) throw new Error("Conversation did not persist across restart");
  await writeFile(join(evidence, "conversation.json"), JSON.stringify({ outcome, script, snapshot }, null, 2));
  const logs = await ox("host", "logs", "--all", "--grep", "MacHost");
  await writeFile(join(evidence, "host-logs.json"), JSON.stringify(logs, null, 2));
  const interrupted = run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, "--conversation", conversation, "conversation", "send", "2", "--timeout", "60000"], { capture: true, allowFailure: true });
  await waitForBusy(conversation);
  await stop();
  await interrupted;
  await start();
  await ox("--conversation", conversation, "conversation", "open");
  const recovered = await ox("--conversation", conversation, "conversation", "inspect", "--full");
  if (recovered.isBusy || !JSON.stringify(recovered.messages).includes("Sorry that took a moment.")) throw new Error("Active run did not settle safely across termination");
  await writeFile(join(evidence, "active-quit.json"), JSON.stringify(recovered, null, 2));
  await stop();
  await start("--disable-connections");
  await Bun.sleep(2000);
  const disabled = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint, "host", "describe", "--timeout", "1000"], { capture: true, allowFailure: true });
  if (!disabled.code) throw new Error("Disabled Host accepted a connection");
  await stop();
  console.log(`PASS native Mac Host: conversation, VM, cancellation, unsupported UI, restart persistence, browser rejection, disabled access, and graceful termination during an active run. Evidence: ${evidence}; retained QA conversation: ${conversation}`);
} finally {
  await stop();
}

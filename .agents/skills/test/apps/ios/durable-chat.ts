import { Database } from "bun:sqlite";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { ROOT, killChildren, run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun run test:agent-ui-ios --device ox-N --app /absolute/Ox.app --evidence /tmp/directory [--bundle id]\nActual temporary-chat UI, native Mock, Pi SQLite and process reopen. Requires an idle chat and Mock already selected. No Host transport or credential changes.",
  options: { app: { type: "string" }, evidence: { type: "string" }, bundle: { type: "string" } },
});
if (!qa.values.device || !qa.values.app) throw new Error("Pass --device and --app from a fresh DEBUG build");
const directory = qa.values.evidence ?? `/tmp/ox-durable-ui-${Date.now()}`;
if (!/^\/tmp\/[^/]+$/.test(directory) || directory.endsWith("/..")) throw new Error("Use a fresh direct child directory of /tmp");
const localConfig = await Bun.file(join(ROOT, "apps/ios/Local.xcconfig")).text().catch(() => "");
const bundle = qa.values.bundle ?? Bun.env.OX_BUNDLE_ID
  ?? /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(localConfig)?.[1] ?? "ai.openox.local";
const caseID = crypto.randomUUID().toUpperCase();
const evidence: Record<string, unknown> = { device: qa.device, bundle, caseID, productionActivated: false, hostTransportUsed: false };
const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
let interrupted = false;
const interrupt = (signal: NodeJS.Signals) => { interrupted = true; killChildren(signal); };
process.once("SIGINT", () => interrupt("SIGINT"));
process.once("SIGTERM", () => interrupt("SIGTERM"));
async function sim(...args: string[]) {
  const { stdout } = await run(["sim", "--device", qa.device, ...args], { capture: true });
  return JSON.parse(stdout);
}
function nodes(value: unknown): Record<string, any>[] {
  if (Array.isArray(value)) return value.flatMap(nodes);
  if (value && typeof value === "object") return [value as Record<string, any>, ...Object.values(value).flatMap(nodes)];
  return [];
}
async function launch(enabled: boolean) {
  evidence.launch = await sim("run", bundle, "--app", qa.values.app!, "--env", `OX_DURABLE_TEMPORARY_SESSION=${enabled ? caseID : ""}`);
  await sim("wait", "--id", "chat.temporaryToggle", "--timeout", "20000", "--stable", "1000");
  const tree = await sim("describe");
  check(nodes(tree).some(node => node.AXUniqueId === "chat.modelPicker" && node.AXLabel === "Model: Mock"), "Select native Mock before the campaign; provider state is not changed automatically");
}
async function logs(): Promise<string[]> {
  await sim("file", "pull", bundle, "Library/Application Support/logs.jsonl", "--dest", `${directory}/logs`);
  return (await Bun.file(`${directory}/logs/logs.jsonl`).text()).split("\n").filter(Boolean).map(line => JSON.parse(line).msg ?? "");
}
async function waitForLog<T>(find: (messages: string[]) => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 60; attempt++) {
    if (interrupted) throw new Error("Replay interrupted; no uncertain send will be retried");
    const found = find(await logs());
    if (found !== undefined) return found;
    await Bun.sleep(200);
  }
  throw new Error("Actual chat did not settle; inspect retained native logs before retrying");
}
async function attach() {
  const attached = (messages: string[]) => messages.map(message => /PiDurable rollout attached chat=([A-F0-9-]+) case=([A-F0-9-]+)/.exec(message))
    .filter(match => match?.[2] === caseID);
  const count = attached(await logs()).length;
  await sim("tap", "--id", "chat.temporaryToggle", "--wait", "5000", "--stable", "200");
  return waitForLog(messages => {
    const matches = attached(messages);
    return matches.length > count ? matches.at(-1)?.[1] : undefined;
  });
}
async function send(chatID: string, text: string, stop = false) {
  const outcome = stop ? "aborted" : "completed";
  const ended = (messages: string[]) => messages.filter(message => message.includes(`Chat.runOne end id=${chatID} outcome=${outcome}`)).length;
  const count = ended(await logs());
  await sim("tap", "--id", "chat.input", "--wait", "5000", "--stable", "1000");
  await sim("wait", "--id", "chat.input", "--stable", "1000");
  await sim("type", text);
  const draft = nodes(await sim("describe")).find(node => node.AXUniqueId === "chat.input");
  check(draft?.AXValue === text, "Composer did not receive exact input; never retry an uncertain send");
  await sim("tap", "--id", "chat.send", "--wait", "5000", "--stable", "200");
  if (stop) {
    await sim("wait", "--id", "chat.stop", "--timeout", "10000");
    await sim("tap", "--id", "chat.stop");
  }
  await waitForLog(messages => ended(messages) > count ? true : undefined);
  await sim("wait", "--id", "chat.stop", "--missing", "--timeout", "10000", "--stable", "1000");
}
async function inspect(name: string) {
  const root = `${directory}/${name}`;
  await sim("file", "pull", bundle, `Library/Caches/PiDurableProof/NativeFiles/${caseID}`, "--dest", root);
  const db = new Database(`${root}/state.sqlite`, { readonly: true });
  try {
    check((db.query("PRAGMA integrity_check").get() as any)?.integrity_check === "ok", "Recovered stopped-process SQLite integrity");
    check((db.query("SELECT count(*) AS n FROM tasks WHERE status != 'terminal'").get() as any).n === 0, "No unfinished Pi tasks");
    check((db.query("SELECT count(*) AS n FROM submissions WHERE status IN ('queued','placed')").get() as any).n === 0, "No pending Pi submissions");
    check(db.query("SELECT name FROM sqlite_master WHERE name IN ('ox_blobs','ox_blob_chunks','ox_chats')").all().length === 0, "Physical backend must not create shadow/binary tables");
    const entries = (db.query("SELECT id, record FROM entries ORDER BY id").all() as { id: number; record: string }[])
      .map(row => ({ id: row.id, record: JSON.parse(row.record) }));
    const conversations = db.query("SELECT id FROM conversations ORDER BY id").all() as { id: number }[];
    return { integrity: "ok", entries, references: conversations.map(row => ({ profileID: caseID, conversationID: row.id })) };
  } finally { db.close(); }
}
const release = claimSimulator(qa.device);
let launched = false;
try {
  check(await requireSimulator(qa.device), "Boot the reserved simulator before replay; no provisioning is performed");
  await mkdir(directory, { recursive: false, mode: 0o700 });
  launched = true;
  await launch(true);
  const firstChat = await attach();
  await send(firstChat, "12");
  check(JSON.stringify(await sim("describe")).includes("Done."), "Native reasoning reply is visible");
  await sim("screenshot", "--out", `${directory}/reasoning.png`);
  await send(firstChat, "10");
  check(JSON.stringify(await sim("describe")).includes("Mock markdown"), "Native markdown reply is visible");
  await sim("screenshot", "--out", `${directory}/two-turns.png`);
  await send(firstChat, "22");
  check(JSON.stringify(await sim("describe")).includes("Both reads are back"), "Native snippet tools return to the Pi model loop");
  await sim("screenshot", "--out", `${directory}/tools.png`);
  await send(firstChat, "13", true);
  await sim("screenshot", "--out", `${directory}/cancelled.png`);
  await launch(true);
  const before = await inspect("before-reopen");
  check(before.references.length === 1, "One Pi conversation before reopen");
  const firstModels = before.entries.flatMap(entry => entry.record.model ?? []);
  check(firstModels.filter(message => message.role === "user").length === 4, "All initial user turns committed exactly once");
  check(firstModels.filter(message => message.role === "toolResult").length === 2, "Both native tool results retained in Pi history");
  check(firstModels.some(message => message.role === "assistant" && message.content.some((block: any) => block.type === "thinking")), "Committed reasoning retained");
  check(firstModels.some(message => message.role === "assistant" && message.content.some((block: any) => block.type === "text" && block.text.includes("# Mock markdown"))), "Full markdown retained in Pi history");
  const secondChat = await attach();
  check(secondChat !== firstChat, "Temporary UI chat identity must not survive process loss");
  await send(secondChat, "12");
  await sim("screenshot", "--out", `${directory}/reopened-session.png`);
  await launch(false);
  const after = await inspect("after-reopen");
  check(after.references.length === 2, "New temporary chat routes to another Pi conversation in reopened Session");
  check(JSON.stringify(after.entries.slice(0, before.entries.length)) === JSON.stringify(before.entries), "Reopening preserves full prior ledger without reseeding");
  check(after.entries.flatMap(entry => entry.record.model ?? []).filter(message => message.role === "user").length === 5, "All actual user turns, no duplicates");
  Object.assign(evidence, { passed: true, firstChat, secondChat, before, after });
  console.log(`PASS actual native UI, reasoning/markdown, native tools, cancellation, qualified identities, physical backend, process reopen and preserved ledger; evidence ${directory}`);
} catch (error) {
  Object.assign(evidence, { passed: false, error: String(error) });
  if (launched) await sim("screenshot", "--out", `${directory}/failure.png`).catch(() => {});
  throw error;
} finally {
  try {
    if (launched) {
      try {
        await sim("run", bundle, "--app", qa.values.app!, "--env", "OX_DURABLE_TEMPORARY_SESSION=");
        evidence.optInCleared = true;
      } catch (error) {
        Object.assign(evidence, { optInCleared: false, restoreError: String(error) });
        process.exitCode ||= 1;
      }
      await Bun.write(`${directory}/report.json`, JSON.stringify(evidence, null, 2));
    }
  } finally { release(); }
}

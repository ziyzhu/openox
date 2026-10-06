import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/guidance.ts --device ox-N --host ws://<VPN-address>:<assigned-port> --chat <id> [--output /tmp/directory]\nRequires a fresh installed build and a fresh empty QA chat. Reads documentation and probes rejected mutations; never changes providers or Profile files.",
  options: { host: { type: "string" }, chat: { type: "string" }, output: { type: "string" } },
});
if (!qa.values.host || !qa.values.chat) throw new Error("Pass an explicit QA Host and chat");
assert.equal(Number(new URL(qa.values.host).port), qa.debugPort, "Use the simulator's assigned Host port");
const directory = resolve(qa.values.output ?? `/tmp/ox-guidance-e2e-${Date.now()}`);
assert(!directory.startsWith(ROOT + "/") && directory !== ROOT, "Keep evidence outside the repository");
const names = ["evolve", "import-memory", "manage-providers", "manage-skills", "visualize"];
const checks: string[] = [];
async function call(name: string, args: Record<string, unknown>) {
  const { stdout } = await run(["ox", "--host", qa.values.host!, "--chat", qa.values.chat!, "vm", "call", name,
    "--args", JSON.stringify({ ...args, purpose: "Verify built-in guidance" }), "--json"], { capture: true });
  return JSON.parse(stdout).value;
}
async function rejected(name: string, args: Record<string, unknown>, message: string) {
  let failure: unknown;
  try { await call(name, args); } catch (error) { failure = error; }
  assert(failure instanceof Error && failure.message.includes(message), `${name} must reject with ${message}`);
  checks.push(`${name}: ${message}`);
}
await requireSimulator(qa.device);
const release = claimSimulator(qa.device);
try {
  await mkdir(directory, { recursive: true });
  const root = await call("ox.fs.list", {});
  assert(root.items.some((item: { path: string }) => item.path === "guidance"));
  const catalog = await call("ox.fs.list", { path: "skills" });
  assert(!catalog.items.some((item: { path: string }) => names.some(name => item.path === `skills/${name}`)));
  checks.push("guidance root present; retired workflows absent from skill listing");
  const found = await call("ox.fs.glob", { path: "guidance", pattern: "**/guide.md" });
  assert.deepEqual(found.paths, names.map(name => `guidance/${name}/guide.md`));
  for (const name of names) {
    const guide = await call("ox.fs.read", { path: `guidance/${name}/guide.md` });
    const legacy = await call("ox.fs.read", { path: `skills/${name}/SKILL.md` });
    assert(guide.text.startsWith("# ") && legacy.text.includes(guide.text.trim()));
  }
  const path = "guidance/manage-skills/guide.md";
  const before = await call("ox.fs.read", { path });
  const references = await call("ox.fs.list", { path: "guidance/manage-skills/references" });
  assert.equal(references.items.length, 2);
  const searched = await call("ox.fs.grep", { path: "guidance/manage-skills", pattern: "Create" });
  assert(searched.matches.length > 0);
  const reference = await call("ox.fs.read", { path: "guidance/manage-skills/references/user-skill.md" });
  const legacyReference = await call("ox.fs.read", { path: "skills/manage-skills/references/user-skill.md" });
  assert.equal(reference.text, legacyReference.text);
  checks.push("all five guides readable; references, searches, and legacy paths resolve");
  await rejected("ox.fs.write", { path, content: "changed" }, "isn't supported");
  await rejected("ox.fs.edit", { path, edits: [{ oldText: "# Manage Skills", newText: "changed" }] }, "isn't supported");
  await rejected("ox.fs.read", { path: "guidance/../MEMORY.md" }, "Invalid Profile file path");
  await rejected("ox.fs.read", { path: "guidance/missing.md" }, "Not a file");
  assert.equal((await call("ox.fs.read", { path })).text, before.text);
  checks.push("rejected mutations leave guidance unchanged");
  console.log(`PASS built-in guidance E2E (${checks.length} checks)`);
} finally {
  try {
    await writeFile(join(directory, "report.json"), JSON.stringify({ device: qa.device, checks }, null, 2) + "\n", { mode: 0o600 });
  } finally { release(); }
}

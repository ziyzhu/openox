import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/profile-files.ts --device ox-N --chat <seeded-saved-Mock-QA-chat> --app /absolute/Ox.app [--bundle id] [--profile-folder name] [--output /tmp/directory]\nWrites run-owned files, creates/deletes a run-owned chat, relaunches, and approves deletion of only its fixtures through ordinary chat approval. Never changes policies or credentials.",
  options: { chat: { type: "string" }, app: { type: "string" }, bundle: { type: "string" }, "profile-folder": { type: "string" }, output: { type: "string" } },
});
if (!qa.values.chat || !qa.values.app) throw new Error("Pass an idle saved Mock QA chat and the freshly built app");
const localConfig = await readFile(join(ROOT, "apps/ios/Local.xcconfig"), "utf8").catch(() => "");
const bundle = qa.values.bundle ?? Bun.env.OX_BUNDLE_ID
  ?? /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(localConfig)?.[1] ?? "ai.openox.local";
const directory = resolve(qa.values.output ?? `/tmp/ox-profile-files-${Date.now()}`);
assert(directory !== ROOT && !directory.startsWith(ROOT + "/"));
const target = ["ox", "--host", qa.debugEndpoint, "--chat", qa.values.chat];
const prefix = `qa-files-${crypto.randomUUID().slice(0, 8)}`;
const shared = `/${prefix}`;
const checks: string[] = [];
let sequence = 0;
async function json(args: string[], allowFailure = false) {
  const result = await run(args, { capture: true, allowFailure });
  await writeFile(join(directory, `${++sequence}.json`), JSON.stringify({ args, ...result }, null, 2) + "\n", { mode: 0o600 });
  return JSON.parse(result.stdout);
}
async function call(name: string, args: Record<string, unknown>) {
  return (await json([...target, "vm", "call", name, "--args", JSON.stringify({ purpose: "Verify Profile filesystem", ...args }), "--json"])).value;
}
async function evaluate(script: string) {
  return (await json([...target, "vm", "eval", "--script", script, "--json"])).value;
}
async function present(path: string) {
  return evaluate(`return await ox.artifact.present({filename:${JSON.stringify(path)},purpose:"Verify live file reference"})`);
}
async function rejected(name: string, args: Record<string, unknown>) {
  await assert.rejects(() => call(name, args));
}
async function waitForHost() {
  for (let attempt = 0; attempt < 40; attempt++) {
    try { await json(["ox", "--host", qa.debugEndpoint, "host", "describe", "--json"]); return; }
    catch { await Bun.sleep(250); }
  }
  throw new Error("Host must become ready after launch");
}
async function approve(script: string, purpose: string) {
  await json([...target, "chat", "send", `execute\n${script}`, "--no-wait", "--json"]);
  for (let attempt = 0; attempt < 100; attempt++) {
    const state = await json([...target, "chat", "inspect", "--pending", "--json"]);
    if (state.pendingPrompt) {
      assert(state.pendingPrompt.prompt.includes(purpose));
      assert(state.pendingPrompt.options.includes("Approve"));
      await json([...target, "chat", "respond", "Approve", "--prompt", state.pendingPrompt.id, "--json"]);
    } else if (!state.isBusy) return;
    await Bun.sleep(100);
  }
  throw new Error("Run-owned fixture cleanup did not settle");
}
await requireSimulator(qa.device);
const release = claimSimulator(qa.device);
try {
  await mkdir(directory, { recursive: true });
  await waitForHost();
  await json([...target, "chat", "open", "--json"]);
  const initial = await json([...target, "chat", "inspect", "--json"]);
  assert.equal(initial.isBusy, false);
  assert.equal(initial.model.id, "mock");
  assert(initial.messages[0]?.user?.content[0]?.text?.text.startsWith("QA filesystem backend verification seed."));
  const root = await call("ox.fs.list", { path: "/" });
  assert(root.items.some((item: { path: string }) => item.path === "history"));
  assert(!root.items.some((item: { path: string }) => /^(state\.sqlite|profile\.json|\.)/.test(item.path)));
  for (const path of ["/state.sqlite", "/state.sqlite-wal", "/state.sqlite-other", "/STATE.SQLITE", "/profile.json", "/.files"]) {
    await rejected("ox.fs.read", { path });
    await rejected("ox.fs.write", { path, content: "Forbidden" });
  }
  checks.push("private Profile material is neither listed nor readable/writable");
  const created = await call("ox.fs.write", { path: `${prefix}/nested/note.md`, content: "# Current file\nVersion one\n" });
  assert.match(created.path, /^conversations\/[0-9]+\//);
  const conversationRoot = created.path.split("/").slice(0, 2).join("/");
  const original = await present(created.path);
  await call("ox.fs.edit", { path: `/${created.path}`, edits: [{ oldText: "Version one", newText: "Version two" }] });
  await rejected("ox.fs.edit", { path: `/${created.path}`, edits: [{ oldText: "Missing", newText: "Unexpected" }] });
  assert.equal((await call("ox.fs.read", { path: `/${created.path}` })).text, "# Current file\nVersion two\n");
  await call("ox.fs.move", { from: `/${conversationRoot}/${prefix}`, to: shared });
  const path = `${shared}/nested/note.md`;
  await assert.rejects(() => present(original.filename));
  const moved = await present(path);
  assert.notEqual(moved.filename, original.filename);
  const copy = await call("ox.fs.copy", { from: path, to: `${shared}/copy.md` });
  assert.notEqual((await present(copy.path)).filename, original.filename);
  await rejected("ox.fs.copy", { from: path, to: `${shared}/copy.md` });
  await call("ox.fs.move", { from: path, to: `${shared}/nested/current.html` });
  await assert.rejects(() => present(moved.filename));
  const current = await present(`${shared}/nested/current.html`);
  assert.equal(current.mimeType, "text/html");
  await call("ox.fs.write", { path: `${shared}/nested/current.html`, content: "<h1>Current HTML</h1>\n" });
  const attachment = await call("ox.fs.attach", { path: `${shared}/nested/current.html` });
  assert.equal(attachment.filename, "current.html");
  assert.equal(attachment.contentType, "text/html");
  assert.equal((await present(current.filename)).filename, current.filename);
  await call("ox.fs.mkdir", { path: `${shared}/empty` });
  await rejected("ox.fs.move", { from: `/${conversationRoot}`, to: `${shared}/illegal` });
  checks.push("conversation cwd, checked edits, moves retiring old references, independent copies, current MIME type and managed roots");
  if (qa.values["profile-folder"]) {
    const folder = qa.values["profile-folder"];
    assert(!folder.includes("/") && ![".", ".."].includes(folder));
    assert.equal((await call("ox.app.profile", {})).name, folder);
    const publicRoot = `Documents/Profiles/${folder}`;
    const sim = ["sim", "--device", qa.device, "file"];
    const listing = await json([...sim, "list", bundle, publicRoot]);
    assert(!listing.some((entry: { name: string }) => /^(profile\.json|state\.sqlite|staging|payloads|\.files|\.migration-conversations)/.test(entry.name)));
    const fixture = join(directory, "external.md"), external = `${publicRoot}/${prefix}-external.md`;
    await writeFile(fixture, "External creation\n");
    await json([...sim, "push", bundle, fixture, external]);
    assert.equal((await call("ox.fs.read", { path: `/${prefix}-external.md` })).text, "External creation\n");
    const externalReference = await present(`/${prefix}-external.md`);
    await writeFile(fixture, "External edit\n");
    await json([...sim, "push", bundle, fixture, external]);
    assert.equal((await call("ox.fs.read", { path: `/${prefix}-external.md` })).text, "External edit\n");
    assert.equal((await present(externalReference.filename)).filename, externalReference.filename);
    await json([...sim, "mv", bundle, external, `${publicRoot}/${prefix}-renamed.md`]);
    await assert.rejects(() => present(externalReference.filename));
    assert.equal((await call("ox.fs.read", { path: `/${prefix}-renamed.md` })).text, "External edit\n");
    const renamedReference = await present(`/${prefix}-renamed.md`);
    await json([...sim, "delete", bundle, `${publicRoot}/${prefix}-renamed.md`]);
    await assert.rejects(() => present(renamedReference.filename));
    await json([...sim, "push", bundle, fixture, `${publicRoot}/${prefix}-renamed.md`]);
    await assert.rejects(() => present(renamedReference.filename));
    assert.notEqual((await present(`/${prefix}-renamed.md`)).filename, renamedReference.filename);
    await json([...sim, "delete", bundle, `${publicRoot}/${prefix}-renamed.md`]);
    const originalDocuments = join(directory, "original-documents"), memory = join(originalDocuments, "MEMORY.md");
    await json([...sim, "pull", bundle, `${publicRoot}/MEMORY.md`, originalDocuments]);
    try {
      await writeFile(fixture, (await readFile(memory, "utf8")) + `\n${prefix} external memory marker\n`);
      await json([...sim, "push", bundle, fixture, `${publicRoot}/MEMORY.md`]);
      assert((await call("ox.fs.read", { path: "/MEMORY.md" })).text.includes(`${prefix} external memory marker`));
    } finally { await json([...sim, "push", bundle, memory, `${publicRoot}/MEMORY.md`]); }
    const skillName = `${prefix}-skill`, skillRoot = `${publicRoot}/skills/${skillName}`;
    await json([...sim, "mkdir", bundle, skillRoot]);
    await writeFile(fixture, `---\nname: ${skillName}\ndescription: Verify external skill editing.\n---\n\nExternal skill marker.\n`);
    await json([...sim, "push", bundle, fixture, `${skillRoot}/SKILL.md`]);
    assert((await call("ox.fs.read", { path: `/skills/${skillName}/SKILL.md` })).text.includes("External skill marker."));
    await call("ox.fs.read", { path: "/skills/manage-skills/SKILL.md" });
    await call("ox.fs.write", { path: `/skills/${skillName}/references/data.txt`, content: "Physical skill data\n" });
    const skillExport = join(directory, "skill-export"), skillData = join(skillExport, "data.txt");
    await json([...sim, "pull", bundle, `${skillRoot}/references/data.txt`, skillExport]);
    assert.equal(await readFile(skillData, "utf8"), "Physical skill data\n");
    await json([...sim, "delete", bundle, skillRoot]);
    await rejected("ox.fs.read", { path: `/skills/${skillName}/references/data.txt` });
    checks.push("public-only content, external create/edit/move/delete/recreate, authoritative Memory and physical user skills");
  }
  await run(["sim", "--device", qa.device, "run", bundle, "--app", resolve(qa.values.app),
    "--env", "OX_HOST_LOOPBACK=1", "--env", `OX_DEBUG_ENDPOINT=${qa.debugEndpoint}`], { capture: true });
  await waitForHost();
  await json([...target, "chat", "open", "--json"]);
  assert.equal((await call("ox.fs.read", { path: `${shared}/nested/current.html` })).text, "<h1>Current HTML</h1>\n");
  assert.equal((await present(current.filename)).filename, current.filename);
  await assert.rejects(() => present(original.filename));
  assert.equal((await call("ox.fs.list", { path: `${shared}/empty` })).items.length, 0);
  checks.push("current file contents, identity, and empty directories persist through process reopen");
  const removalPurpose = `Remove ${prefix}`;
  await approve(`return await ox.fs.rmdir({path:${JSON.stringify(shared)},recursive:true,purpose:${JSON.stringify(removalPurpose)}})`, removalPurpose);
  assert(!(await call("ox.fs.list", { path: "/" })).items.some((item: { path: string }) => item.path === prefix));
  await assert.rejects(() => present(original.filename));
  await rejected("ox.fs.read", { path: `${shared}/nested/current.html` });
  checks.push("ordinary approval deletes the run-owned directory recursively and makes live references unavailable");
  const host = ["ox", "--host", qa.debugEndpoint];
  await json([...host, "chat", "new", "--provider", "mock", "--model", "mock", "--json"]);
  await json([...host, "chat", "send", `QA filesystem ownership ${prefix}. Reply QA only.`, "--json"]);
  const child = await json([...host, "chat", "inspect", "--json"]);
  assert.notEqual(child.id, qa.values.chat);
  const childFile = (await json([...host, "--chat", child.id, "vm", "call", "ox.fs.write", "--args",
    JSON.stringify({ path: `${prefix}/owned.md`, content: "Conversation-owned content\n", purpose: "Verify conversation ownership" }), "--json"])).value;
  const childRoot = childFile.path.split("/").slice(0, 2).join("/");
  const ownedReference = await present(childFile.path);
  const ownershipRoot = `${shared}-ownership`;
  await call("ox.fs.move", { from: `/${childFile.path}`, to: `${ownershipRoot}/shared.md` });
  await call("ox.fs.copy", { from: `${ownershipRoot}/shared.md`, to: `${ownershipRoot}/survivor.md` });
  await call("ox.fs.move", { from: `${ownershipRoot}/shared.md`, to: `/${childRoot}/returned.md` });
  await json([...target, "chat", "open", "--json"]);
  const deletionPurpose = `Delete ${prefix} chat`;
  await approve(`return await ox.conversation.delete({id:${JSON.stringify(child.id)},purpose:${JSON.stringify(deletionPurpose)}})`, deletionPurpose);
  assert(!(await call("ox.fs.list", { path: "/conversations" })).items.some((item: { path: string }) => item.path === childRoot));
  await assert.rejects(() => present(ownedReference.filename));
  assert.equal((await call("ox.fs.read", { path: `${ownershipRoot}/survivor.md` })).text, "Conversation-owned content\n");
  checks.push("conversation deletion reclaims transferred-back owned files without retaining referenced bytes or deleting shared copies");
  await approve(`return await ox.fs.rmdir({path:${JSON.stringify(ownershipRoot)},recursive:true,purpose:${JSON.stringify(removalPurpose)}})`, removalPurpose);
  console.log(`PASS Profile filesystem E2E (${checks.length} check groups)`);
} finally {
  try {
    await writeFile(join(directory, "report.json"), JSON.stringify({ device: qa.device, chat: qa.values.chat, prefix, checks,
      limitations: ["No physical-device power-loss test", "No predecessor fixture, provider submission, or package round-trip test"] }, null, 2) + "\n", { mode: 0o600 });
  } finally { release(); }
}

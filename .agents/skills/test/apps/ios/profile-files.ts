import assert from "node:assert/strict";
import { copyFile, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../setup/scripts/simulator.ts";
import { iosTarget } from "../../../setup/scripts/ios.ts";
import { waitForHost } from "./host.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/profile-files.ts --device ox-N --conversation <seeded-saved-Mock-QA-conversation> --app /absolute/Ox.app [--bundle id] [--profile-folder name] [--files-grant id] [--output /tmp/directory]\nWrites run-owned files, creates/deletes a run-owned conversation, relaunches, and approves deletion of only its fixtures through ordinary conversation approval. Never changes policies or credentials.",
  options: { conversation: { type: "string" }, app: { type: "string" }, bundle: { type: "string" }, "profile-folder": { type: "string" }, "files-grant": { type: "string" }, output: { type: "string" } },
});
if (!qa.values.conversation || !qa.values.app) throw new Error("Pass an idle saved Mock QA conversation and the freshly built app");
const localConfig = await readFile(join(ROOT, "apps/ios/Local.xcconfig"), "utf8").catch(() => "");
const bundle = qa.values.bundle ?? Bun.env.OX_BUNDLE_ID
  ?? /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(localConfig)?.[1] ?? "ai.openox.local";
const directory = resolve(qa.values.output ?? `/tmp/ox-profile-files-${Date.now()}`);
assert(directory !== ROOT && !directory.startsWith(ROOT + "/"));
const target = ["ox", "--host", qa.debugEndpoint, "--conversation", qa.values.conversation];
const ios = iosTarget(qa.device);
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
async function inspectFile(path: string) {
  const filename = path.startsWith("/") ? path : `/${path}`;
  await call("ox.fs.read", { path: filename });
  return { filename };
}
async function rejected(name: string, args: Record<string, unknown>) {
  await assert.rejects(() => call(name, args));
}
const ready = () => waitForHost(qa.debugEndpoint,
  () => json(["ox", "--host", qa.debugEndpoint, "host", "describe", "--timeout", "1000", "--json"]), 10_000);
async function approve(script: string, purpose: string) {
  await json([...target, "conversation", "send", `execute\n${script}`, "--no-wait", "--json"]);
  for (let attempt = 0; attempt < 100; attempt++) {
    const state = await json([...target, "conversation", "inspect", "--pending", "--json"]);
    if (state.pendingPrompt) {
      assert(state.pendingPrompt.prompt.includes(purpose));
      assert(state.pendingPrompt.options.includes("Approve"));
      await json([...target, "conversation", "respond", "Approve", "--prompt", state.pendingPrompt.id, "--json"]);
    } else if (!state.isBusy) return;
    await Bun.sleep(100);
  }
  throw new Error("Run-owned fixture cleanup did not settle");
}
await requireSimulator(qa.device);
const release = claimSimulator(qa.device);
try {
  await mkdir(directory, { recursive: true });
  await ready();
  await json([...target, "conversation", "open", "--json"]);
  const initial = await json([...target, "conversation", "inspect", "--json"]);
  assert.equal(initial.isBusy, false);
  assert.equal(initial.model.id, "mock");
  assert(initial.messages[0]?.user?.content[0]?.text?.text.startsWith("QA filesystem backend verification seed."));
  const root = await call("ox.fs.list", { path: "/" });
  assert(root.items.some((item: { path: string }) => item.path === "conversations"));
  assert(!root.items.some((item: { path: string }) => ["history", "chats"].includes(item.path)));
  assert(!root.items.some((item: { path: string }) => /^(state\.sqlite|profile\.json|\.)/.test(item.path)));
  for (const path of ["/state.sqlite", "/state.sqlite-wal", "/state.sqlite-other", "/STATE.SQLITE", "/profile.json", "/.files"]) {
    await rejected("ox.fs.read", { path });
    await rejected("ox.fs.write", { path, content: "Forbidden" });
  }
  checks.push("private Profile material is neither listed nor readable/writable");
  const created = await call("ox.fs.write", { path: `${prefix}/nested/note.md`, content: "# Current file\nVersion one\n" });
  assert.match(created.path, /^conversations\/[0-9]+\//);
  const conversationRoot = created.path.split("/").slice(0, 2).join("/");
  const entries = (await call("ox.fs.list", { path: `/${conversationRoot}` })).items;
  for (const name of ["conversation.json", "turns.jsonl", prefix]) assert(entries.some((item: { path: string }) => item.path === `${conversationRoot}/${name}`));
  const transcript = `${conversationRoot}/turns.jsonl`;
  const history = await call("ox.fs.read", { path: `/${transcript}`, limit: 1 });
  assert(history.text.includes("QA filesystem backend verification seed."));
  const alias = await call("ox.fs.read", { path: `/history/${conversationRoot.split("/")[1]}/turns.jsonl`, limit: 1 });
  assert.deepEqual(JSON.parse(alias.text), JSON.parse(history.text));
  for (const name of ["conversation.json", "turns.jsonl"]) {
    await rejected("ox.fs.write", { path: `/${conversationRoot}/${name}`, content: "Forbidden" });
    await rejected("ox.fs.mkdir", { path: `/${conversationRoot}/${name}/nested`, recursive: true });
  }
  const search = { pattern: "QA filesystem backend verification seed.", options: { literal: true, glob: "**/turns.jsonl" } };
  assert((await call("ox.fs.grep", { ...search, path: "/conversations" })).matches.some((match: { path: string }) => match.path === transcript));
  assert.equal((await call("ox.fs.grep", { ...search, path: "/" })).matches.length, 0);
  checks.push("unified conversation records and files, old history aliases, read-only reserved names and explicit transcript search");
  const original = await inspectFile(created.path);
  await call("ox.fs.edit", { path: `/${created.path}`, edits: [{ oldText: "Version one", newText: "Version two" }] });
  await rejected("ox.fs.edit", { path: `/${created.path}`, edits: [{ oldText: "Missing", newText: "Unexpected" }] });
  assert.equal((await call("ox.fs.read", { path: `/${created.path}` })).text, "# Current file\nVersion two\n");
  await call("ox.fs.move", { from: `/${conversationRoot}/${prefix}`, to: shared });
  const path = `${shared}/nested/note.md`;
  await assert.rejects(() => inspectFile(original.filename));
  const moved = await inspectFile(path);
  assert.notEqual(moved.filename, original.filename);
  const copy = await call("ox.fs.copy", { from: path, to: `${shared}/copy.md` });
  assert.notEqual((await inspectFile(copy.path)).filename, original.filename);
  await rejected("ox.fs.copy", { from: path, to: `${shared}/copy.md` });
  await call("ox.fs.move", { from: path, to: `${shared}/nested/current.html` });
  await assert.rejects(() => inspectFile(moved.filename));
  const current = await inspectFile(`${shared}/nested/current.html`);
  await call("ox.fs.write", { path: `${shared}/nested/current.html`, content: "<h1>Current HTML</h1>\n" });
  const attachment = await call("ox.fs.attach", { path: `${shared}/nested/current.html` });
  assert.equal(attachment.filename, "current.html");
  assert.equal(attachment.contentType, "text/html");
  assert.equal((await inspectFile(current.filename)).filename, current.filename);
  await call("ox.fs.mkdir", { path: `${shared}/empty` });
  await call("ox.fs.copy", { from: `${shared}/nested`, to: `${shared}/nested-copy` });
  const directoryCopy = await inspectFile(`${shared}/nested-copy/current.html`);
  assert.notEqual(directoryCopy.filename, current.filename);
  assert.equal((await call("ox.fs.read", { path: `${shared}/nested-copy/current.html` })).text, "<h1>Current HTML</h1>\n");
  await rejected("ox.fs.copy", { from: `${shared}/nested`, to: `${shared}/nested/inside` });
  await rejected("ox.fs.copy", { from: `/${conversationRoot}`, to: `${shared}/illegal-copy` });
  await rejected("ox.fs.move", { from: `/${conversationRoot}`, to: `${shared}/illegal` });
  checks.push("conversation cwd, checked edits, moves retiring old references, independent file and directory copies, current MIME type and managed roots");
  if (qa.values["profile-folder"]) {
    const folder = qa.values["profile-folder"];
    assert(!folder.includes("/") && ![".", ".."].includes(folder));
    assert.equal((await call("ox.app.profile", {})).name, folder);
    const publicRoot = `Documents/Profiles/${folder}`;
    const physical = (path: string) => ios.containerPath(bundle, path);
    const listing = await readdir(await physical(publicRoot), { withFileTypes: true });
    assert(!listing.some((entry: { name: string }) => /^(profile\.json|state\.sqlite|staging|payloads|\.files|\.migration-conversations)/.test(entry.name)));
    const fixture = join(directory, "external.md"), external = `${publicRoot}/${prefix}-external.md`;
    await writeFile(fixture, "External creation\n");
    await copyFile(fixture, await physical(external));
    assert.equal((await call("ox.fs.read", { path: `/${prefix}-external.md` })).text, "External creation\n");
    const externalReference = await inspectFile(`/${prefix}-external.md`);
    await writeFile(fixture, "External edit\n");
    await copyFile(fixture, await physical(external));
    assert.equal((await call("ox.fs.read", { path: `/${prefix}-external.md` })).text, "External edit\n");
    assert.equal((await inspectFile(externalReference.filename)).filename, externalReference.filename);
    await rename(await physical(external), await physical(`${publicRoot}/${prefix}-renamed.md`));
    await assert.rejects(() => inspectFile(externalReference.filename));
    assert.equal((await call("ox.fs.read", { path: `/${prefix}-renamed.md` })).text, "External edit\n");
    const renamedReference = await inspectFile(`/${prefix}-renamed.md`);
    await rm(await physical(`${publicRoot}/${prefix}-renamed.md`));
    await assert.rejects(() => inspectFile(renamedReference.filename));
    await copyFile(fixture, await physical(`${publicRoot}/${prefix}-renamed.md`));
    assert.equal((await call("ox.fs.read", { path: renamedReference.filename })).text, "External edit\n");
    await rm(await physical(`${publicRoot}/${prefix}-renamed.md`));
    const originalDocuments = join(directory, "original-documents"), memory = join(originalDocuments, "MEMORY.md");
    await ios.pull(bundle, `${publicRoot}/MEMORY.md`, originalDocuments);
    try {
      await writeFile(fixture, (await readFile(memory, "utf8")) + `\n${prefix} external memory marker\n`);
      await copyFile(fixture, await physical(`${publicRoot}/MEMORY.md`));
      assert((await call("ox.fs.read", { path: "/MEMORY.md" })).text.includes(`${prefix} external memory marker`));
    } finally { await copyFile(memory, await physical(`${publicRoot}/MEMORY.md`)); }
    const skillName = `${prefix}-skill`, skillRoot = `${publicRoot}/skills/${skillName}`;
    await mkdir(await physical(skillRoot), { recursive: true });
    await writeFile(fixture, `---\nname: ${skillName}\ndescription: Verify external skill editing.\n---\n\nExternal skill marker.\n`);
    await copyFile(fixture, await physical(`${skillRoot}/SKILL.md`));
    assert((await call("ox.fs.read", { path: `/skills/${skillName}/SKILL.md` })).text.includes("External skill marker."));
    await call("ox.fs.read", { path: "/skills/manage-skills/SKILL.md" });
    await call("ox.fs.write", { path: `/skills/${skillName}/references/data.txt`, content: "Physical skill data\n" });
    const skillExport = join(directory, "skill-export"), skillData = join(skillExport, "data.txt");
    await ios.pull(bundle, `${skillRoot}/references/data.txt`, skillExport);
    assert.equal(await readFile(skillData, "utf8"), "Physical skill data\n");
    await rm(await physical(skillRoot), { recursive: true });
    await rejected("ox.fs.read", { path: `/skills/${skillName}/references/data.txt` });
    checks.push("public-only content, external create/edit/move/delete/recreate, authoritative Memory and physical user skills");
  }
  if (qa.values["files-grant"]) {
    const mounted = `/files/${qa.values["files-grant"]}/${prefix}`, pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    await call("ox.fs.write", { path: `${mounted}/new/note.md`, content: "Version one\n" });
    await call("ox.fs.edit", { path: `${mounted}/new/note.md`, edits: [{ oldText: "Version one", newText: "Version two" }] });
    assert.equal((await call("ox.fs.write", { path: `${mounted}/new/pixel.png`, base64: pixel })).size, 70);
    await call("ox.fs.mkdir", { path: `${mounted}/deep/nested`, recursive: true });
    await call("ox.fs.mkdir", { path: `${mounted}/deep/nested`, recursive: true });
    await call("ox.fs.copy", { from: `${mounted}/new/note.md`, to: `${mounted}/deep/copy.md` });
    await rejected("ox.fs.copy", { from: `${mounted}/new/note.md`, to: `${mounted}/deep/copy.md` });
    await call("ox.fs.copy", { from: `${mounted}/deep`, to: `${mounted}/deep-copy` });
    assert.equal((await call("ox.fs.read", { path: `${mounted}/deep-copy/copy.md` })).text, "Version two\n");
    assert((await call("ox.fs.list", { path: `${mounted}/deep-copy` })).items.some((item: { path: string }) => item.path.endsWith("/deep-copy/nested")));
    await rejected("ox.fs.copy", { from: `${mounted}/deep`, to: `${mounted}/deep/inside` });
    await call("ox.fs.move", { from: `${mounted}/deep`, to: `${mounted}/moved` });
    assert.equal((await call("ox.fs.read", { path: `${mounted}/moved/copy.md` })).text, "Version two\n");
    await rejected("ox.fs.move", { from: `${mounted}/new/note.md`, to: `${shared}/from-files.md` });
    await rejected("ox.fs.move", { from: `${mounted}/new/note.md`, to: `/files/${prefix}-other/note.md` });
    const mountedPurpose = `Remove mounted ${prefix}`;
    await approve(`return await ox.fs.rm({path:${JSON.stringify(mounted)},recursive:true,purpose:${JSON.stringify(mountedPurpose)}})`, mountedPurpose);
    await rejected("ox.fs.list", { path: mounted });
    checks.push("chosen Files folders support text and binary writes, edits, directories, in-folder file and directory copies and moves, and approved recursive removal, but reject cross-mount transfers");
  }
  await ios.launch(bundle, resolve(qa.values.app), { OX_HOST_LOOPBACK: "1", OX_DEBUG_ENDPOINT: qa.debugEndpoint });
  await ready();
  await json([...target, "conversation", "open", "--json"]);
  assert.equal((await call("ox.fs.read", { path: `${shared}/nested/current.html` })).text, "<h1>Current HTML</h1>\n");
  assert.equal((await inspectFile(current.filename)).filename, current.filename);
  await assert.rejects(() => inspectFile(original.filename));
  assert.equal((await call("ox.fs.list", { path: `${shared}/empty` })).items.length, 0);
  checks.push("current file contents, paths, and empty directories persist through process reopen");
  const removalPurpose = `Remove ${prefix}`;
  await approve(`return await ox.fs.rm({path:${JSON.stringify(shared)},recursive:true,purpose:${JSON.stringify(removalPurpose)}})`, removalPurpose);
  assert(!(await call("ox.fs.list", { path: "/" })).items.some((item: { path: string }) => item.path === prefix));
  await assert.rejects(() => inspectFile(original.filename));
  await rejected("ox.fs.read", { path: `${shared}/nested/current.html` });
  checks.push("ordinary approval deletes the run-owned directory recursively and makes live references unavailable");
  const host = ["ox", "--host", qa.debugEndpoint];
  await json([...host, "conversation", "new", "--provider", "mock", "--model", "mock", "--json"]);
  await json([...host, "conversation", "send", `QA filesystem ownership ${prefix}. Reply QA only.`, "--json"]);
  const child = await json([...host, "conversation", "inspect", "--json"]);
  assert.notEqual(child.id, qa.values.conversation);
  const childFile = (await json([...host, "--conversation", child.id, "vm", "call", "ox.fs.write", "--args",
    JSON.stringify({ path: `${prefix}/owned.md`, content: "Conversation-owned content\n", purpose: "Verify conversation ownership" }), "--json"])).value;
  const childRoot = childFile.path.split("/").slice(0, 2).join("/");
  const ownedReference = await inspectFile(childFile.path);
  const ownershipRoot = `${shared}-ownership`;
  await call("ox.fs.move", { from: `/${childFile.path}`, to: `${ownershipRoot}/shared.md` });
  await call("ox.fs.copy", { from: `${ownershipRoot}/shared.md`, to: `${ownershipRoot}/survivor.md` });
  await call("ox.fs.move", { from: `${ownershipRoot}/shared.md`, to: `/${childRoot}/returned.md` });
  await json([...target, "conversation", "open", "--json"]);
  const deletionPurpose = `Delete ${prefix} conversation`;
  await approve(`return await ox.conversation.delete({id:${JSON.stringify(child.id)},purpose:${JSON.stringify(deletionPurpose)}})`, deletionPurpose);
  assert(!(await call("ox.fs.list", { path: "/conversations" })).items.some((item: { path: string }) => item.path === childRoot));
  await assert.rejects(() => inspectFile(ownedReference.filename));
  assert.equal((await call("ox.fs.read", { path: `${ownershipRoot}/survivor.md` })).text, "Conversation-owned content\n");
  checks.push("conversation deletion reclaims transferred-back owned files without retaining referenced bytes or deleting shared copies");
  await approve(`return await ox.fs.rm({path:${JSON.stringify(ownershipRoot)},recursive:true,purpose:${JSON.stringify(removalPurpose)}})`, removalPurpose);
  console.log(`PASS Profile filesystem E2E (${checks.length} check groups)`);
} finally {
  try {
    await writeFile(join(directory, "report.json"), JSON.stringify({ device: qa.device, conversation: qa.values.conversation, prefix, checks,
      limitations: ["No physical-device power-loss test", "No predecessor fixture, provider submission, or package round-trip test", "Historical reference retirement is not checked through the removed presentation API"] }, null, 2) + "\n", { mode: 0o600 });
  } finally { release(); }
}

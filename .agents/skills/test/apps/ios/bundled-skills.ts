import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";
import { bundledSkills } from "../../../../../packages/agent/src/core/bundled-skills.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/bundled-skills.ts --device ox-N --host ws://<assigned-host> --chat <seeded-saved-QA-chat> --temporary-chat <empty-temporary-QA-chat> [--ui-cleanup] [--output /tmp/directory]\nFor --ui-cleanup, leave the app on this Profile's Skills screen. Otherwise deletion policy must allow cleanup. Seed the saved Mock chat with `QA bundled skill verification seed. Reply QA only.` before creating the temporary chat. Copies/removes one run-owned Profile skill. Provider probes never save configuration.",
  options: { host: { type: "string" }, chat: { type: "string" }, "temporary-chat": { type: "string" }, "ui-cleanup": { type: "boolean" }, output: { type: "string" } },
});
if (!qa.values.host || !qa.values.chat || !qa.values["temporary-chat"]) throw new Error("Pass explicit saved and temporary QA chats");
assert.equal(Number(new URL(qa.values.host).port), qa.debugPort);
const directory = resolve(qa.values.output ?? `/tmp/ox-bundled-skills-${Date.now()}`);
assert(!directory.startsWith(ROOT + "/") && directory !== ROOT);
const checks: string[] = [];
const copied = `qa-skill-${crypto.randomUUID().slice(0, 8)}`;
let created = false;
async function call(name: string, args: Record<string, unknown>, chat = qa.values.chat!) {
  const { stdout } = await run(["ox", "--host", qa.values.host!, "--chat", chat, "vm", "call", name,
    "--args", JSON.stringify({ ...args, purpose: "Verify bundled System skills" }), "--json"], { capture: true });
  return JSON.parse(stdout).value;
}
async function rejected(name: string, args: Record<string, unknown>, message: RegExp, chat = qa.values.chat!) {
  let failure: unknown;
  try { await call(name, args, chat); } catch (error) { failure = error; }
  assert(failure instanceof Error && message.test(failure.message), `${name}: expected ${message}, received ${failure}`);
  checks.push(`${name}: rejected ${message}`);
}
async function providerProbe(expected: string) {
  const { stdout } = await run(["ox", "--host", qa.values.host!, "--chat", qa.values["temporary-chat"]!, "vm", "eval", "--script", `
    const provider = (await ox.provider.default({ purpose: "Inspect the bundled provider schema" }))[0];
    try { await ox.provider.save({ provider, purpose: "Verify the temporary-chat boundary" }); throw Error("Unexpected save"); }
    catch (error) { if (!String(error).includes(${JSON.stringify(expected)})) throw error; console.log("Expected refusal"); }
  `, "--json"], { capture: true });
  assert(JSON.stringify(JSON.parse(stdout).logs).includes("Expected refusal"));
  checks.push(`provider save refused: ${expected}`);
}
await requireSimulator(qa.device);
const release = claimSimulator(qa.device);
try {
  await mkdir(directory, { recursive: true });
  for (const [chat, temporary] of [[qa.values.chat, false], [qa.values["temporary-chat"], true]] as const) {
    const { stdout } = await run(["ox", "--host", qa.values.host, "--chat", chat, "chat", "inspect", "--json"], { capture: true });
    const state = JSON.parse(stdout);
    assert(state && state.isBusy === false, "Use idle QA chats");
    const users = state.messages.filter((message: { type: string }) => message.type === "user");
    assert(temporary ? users.length === 0 : users.length === 1 && JSON.stringify(users[0]).includes("QA bundled skill verification seed."), "Use the seeded saved QA chat and an empty temporary chat");
    const inspected = await run(["ox", "--host", qa.values.host, "--chat", chat, "vm", "inspect", "--json"], { capture: true });
    assert.equal(JSON.parse(inspected.stdout).value.session.temporary, temporary);
  }
  const expected = await run(["bun", "-e", "import {filesystemInputs} from './packages/agent/src/core/filesystem-contract.ts'; console.log(JSON.stringify(filesystemInputs));"], { capture: true });
  const functions = await run(["ox", "--host", qa.values.host, "vm", "functions", "--json"], { capture: true });
  const schemas = JSON.parse(functions.stdout);
  for (const name of ["read", "write", "edit"]) assert.deepEqual(schemas[`ox.fs.${name}`].inputSchema, JSON.parse(expected.stdout)[name]);
  for (const [name, schema] of Object.entries(schemas) as [string, { inputSchema: { required: string[] } }][]) {
    assert.equal(schema.inputSchema.required[0], "purpose", `${name} requires purpose first`);
  }
  const rejectedPurposes = await run(["ox", "--host", qa.values.host, "--chat", qa.values.chat, "vm", "eval", "--script", `
    for (const name of Object.keys(ox.fs)) {
      for (const args of [{}, { purpose: "" }, { purpose: "x".repeat(81) }]) {
        try { await ox.fs[name](args); throw Error(name + " accepted invalid purpose"); }
        catch (error) { if (!error.message.includes("purpose")) throw error; }
      }
    }
    return true;
  `, "--json"], { capture: true });
  assert.equal(JSON.parse(rejectedPurposes.stdout).value, true);
  checks.push("all built-ins require purpose first; filesystem rejects missing, empty, and oversized purposes before effects");
  checks.push("native read/write/edit contracts are generated from pinned Pi schemas; purpose is required and listed first");
  const root = await call("ox.fs.list", {});
  assert(!root.items.some((item: { path: string }) => item.path === "guidance"));
  const catalog = await call("ox.fs.list", { path: "skills", options: { limit: 100 } });
  for (const skill of bundledSkills) assert(catalog.items.some((item: { path: string }) => item.path === `skills/${skill.name}`));
  const found = await call("ox.fs.glob", { path: "skills", pattern: "**/SKILL.md", options: { limit: 1000 } });
  for (const skill of bundledSkills) assert(found.paths.includes(`skills/${skill.name}/SKILL.md`));
  checks.push("one skills surface; all five bundled packages discoverable; no guidance root");
  for (const skill of bundledSkills) {
    const canonical = await call("ox.fs.read", { path: `skills/${skill.name}/SKILL.md` });
    const legacy = await call("ox.fs.read", { path: `guidance/${skill.name}/guide.md` });
    assert.equal(canonical.text, skill.files["SKILL.md"]);
    assert.equal(legacy.text, canonical.text);
    assert.equal(legacy.path, `skills/${skill.name}/SKILL.md`);
    for (const [resource, text] of Object.entries(skill.resources)) {
      assert.equal((await call("ox.fs.read", { path: `skills/${skill.name}/${resource}` })).text, text);
      assert.equal((await call("ox.fs.read", { path: `guidance/${skill.name}/${resource}` })).text, text);
    }
  }
  checks.push("canonical packages and all references/helpers are byte-identical; old paths return canonical skills");
  const path = "skills/manage-skills/SKILL.md";
  const before = await call("ox.fs.read", { path });
  assert((await call("ox.fs.grep", { path: "skills/manage-skills", pattern: "Create" })).matches.length > 0);
  await rejected("ox.fs.write", { path, content: "changed" }, /reserved|isn't supported|read-only/);
  await rejected("ox.fs.edit", { path, edits: [{ oldText: "# Manage Skills", newText: "changed" }] }, /reserved|isn't supported|read-only/);
  await rejected("ox.fs.delete", { path }, /reserved|isn't supported|read-only/);
  await rejected("ox.fs.write", { path: "guidance/manage-skills/guide.md", content: "changed" }, /reserved|isn't supported|read-only/);
  await rejected("ox.fs.read", { path: "guidance/../MEMORY.md" }, /Invalid (Profile file|virtual) path/);
  await rejected("ox.fs.read", { path: "skills/manage-skills/references/missing.md" }, /No skill named|missing|not found/i);
  assert.equal((await call("ox.fs.read", { path })).text, before.text);
  const copy = await call("ox.skill.copy", { source: "manage-skills", name: copied });
  assert.equal(copy.name, copied); created = true;
  const copyPath = `skills/${copied}/SKILL.md`;
  const copyText = (await call("ox.fs.read", { path: copyPath })).text;
  assert(copyText.includes(`name: ${copied}`) && copyText.includes("`references/user-skill.md`"));
  for (const [resource, text] of Object.entries(bundledSkills.find(skill => skill.name === "manage-skills")!.resources)) {
    assert.equal((await call("ox.fs.read", { path: `skills/${copied}/${resource}` })).text, text);
  }
  await call("ox.fs.edit", { path: copyPath, edits: [{ oldText: "# Manage Skills", newText: "# Customized Skills" }] });
  assert((await call("ox.fs.read", { path: copyPath })).text.includes("# Customized Skills"));
  assert.equal((await call("ox.fs.read", { path })).text, before.text);
  checks.push("copy retains package resources and relative links, is editable, and cannot change the System original");
  const pagePath = `skills/${copied}/references/qa-pages.md`;
  const lines = Array.from({ length: 4_501 }, (_, index) => `line-${index + 1}: 你好 😀`);
  await call("ox.fs.write", { path: pagePath, content: lines.join("\n") });
  const selected = await call("ox.fs.read", { path: "/" + pagePath, offset: 10, limit: 3 });
  assert.equal(selected.text, lines.slice(9, 12).join("\n"));
  assert.equal(selected.nextOffset, 13); assert.equal(selected.truncated, true);
  let offset = 1; const pages: string[] = [];
  do {
    const page = await call("ox.fs.read", { path: pagePath, offset });
    assert(Buffer.byteLength(page.text) <= 50 * 1024);
    assert(page.text.split("\n").length <= 2_000);
    pages.push(page.text);
    offset = page.nextOffset;
    assert.equal(page.truncated, offset !== null);
  } while (offset !== null);
  assert.equal(pages.join("\n"), lines.join("\n"));
  await rejected("ox.fs.read", { path: pagePath, offset: 0 }, /Invalid filesystem limit/);
  await rejected("ox.fs.read", { path: pagePath, offset: 1.5 }, /Invalid filesystem limit/);
  await rejected("ox.fs.read", { path: pagePath, limit: 0 }, /Invalid filesystem limit/);
  await rejected("ox.fs.read", { path: pagePath, offset: lines.length + 1 }, /beyond end of file/);
  await rejected("ox.fs.read", { path: pagePath, options: { maxBytes: 10 } }, /Invalid ox.fs.read arguments/);
  const longPath = `skills/${copied}/references/qa-long-line.md`;
  await call("ox.fs.write", { path: longPath, content: "😀".repeat(20_000) });
  const longLine = await call("ox.fs.read", { path: longPath });
  assert.equal(longLine.truncated, true); assert.equal(longLine.nextOffset, null);
  assert(Buffer.byteLength(longLine.text) <= 50 * 1024 && !longLine.text.includes("\uFFFD"));
  assert(longLine.diagnostics.some((value: { message: string }) => value.message.includes("cannot be resumed")));
  assert(!JSON.stringify(longLine.diagnostics).includes("bash"));
  checks.push("one-indexed read windows and bounded continuation reconstruct Unicode text; oversized lines report explicit non-resumable clipping");
  const editPath = `skills/${copied}/references/qa-edit.md`;
  const original = "\uFEFFalpha\r\nbeta\r\ngamma\r\n";
  await call("ox.fs.write", { path: editPath, content: original });
  const edited = await call("ox.fs.edit", { path: editPath, edits: [{ oldText: "alpha", newText: "ALPHA" }, { oldText: "gamma", newText: "GAMMA" }] });
  assert.equal(edited.firstChangedLine, 1); assert(edited.patch.includes("ALPHA") && edited.diff.includes("GAMMA"));
  assert.equal((await call("ox.fs.read", { path: editPath })).text, "ALPHA\r\nbeta\r\nGAMMA\r\n");
  await rejected("ox.fs.edit", { path: editPath, edits: [{ oldText: "", newText: "append" }] }, /non-empty/);
  await rejected("ox.fs.edit", { path: editPath, edits: [{ oldText: "ALPHA", newText: "a" }, { oldText: "LPH", newText: "b" }] }, /overlap/);
  await rejected("ox.fs.edit", { path: editPath, edits: [{ oldText: "ALPHA ", newText: "unsafe fuzzy match" }] }, /exactly once/);
  const { stdout: parallel } = await run(["ox", "--host", qa.values.host, "--chat", qa.values.chat, "vm", "eval", "--script", `
    await Promise.all([
      ox.fs.edit({ purpose: "Verify parallel edits", path: ${JSON.stringify(editPath)}, edits: [{ oldText: "ALPHA", newText: "first" }] }),
      ox.fs.edit({ purpose: "Verify parallel edits", path: ${JSON.stringify(editPath)}, edits: [{ oldText: "GAMMA", newText: "second" }] })
    ]); console.log("Parallel edits completed");
  `, "--json"], { capture: true });
  assert(parallel.includes("Parallel edits completed"));
  assert.equal((await call("ox.fs.read", { path: editPath })).text, "first\r\nbeta\r\nsecond\r\n");
  checks.push("exact multi-edit accepts BOM/CRLF, reports Pi diffs, rejects ambiguity, and serializes parallel edits");
  assert((await call("ox.fs.grep", { path: `skills/${copied}`, pattern: "line-4501", options: { literal: true } })).matches.some((match: { path: string }) => match.path === pagePath));
  await rejected("ox.fs.grep", { path: pagePath, pattern: "(line)\\1" }, /invalid|escape|backreference/i);
  await call("ox.fs.grep", { path: pagePath, pattern: "(a+)+$" });
  checks.push("shared traversal/search uses bounded linear-time matching");
  await rejected("ox.fs.write", { path: `conversations/${qa.values.chat}/conversation.json`, content: "changed" }, /isn't supported|read-only/);
  await rejected("ox.fs.read", { path: "state.sqlite" }, /Invalid Profile file path/);
  await rejected("ox.fs.read", { path: `conversations/${qa.values.chat}/context.json` }, /Invalid Profile file path/);
  await call("ox.fs.grep", { path: "skills/manage-providers", pattern: "Manage" }, qa.values["temporary-chat"]);
  await providerProbe("activate the bundled System skill");
  await call("ox.fs.read", { path: copyPath }, qa.values["temporary-chat"]);
  await rejected("ox.fs.write", { path: pagePath, content: "Temporary mutation must fail" }, /Temporary chats can't save changes/, qa.values["temporary-chat"]);
  await providerProbe("activate the bundled System skill");
  await call("ox.fs.read", { path: "skills/manage-providers/SKILL.md" }, qa.values["temporary-chat"]);
  await providerProbe("Temporary chats can't save changes");
} finally {
  try {
    if (created) {
      if (qa.values["ui-cleanup"]) {
        await run(["sim", "--device", qa.device, "tap", "--label", `/${copied}`, "--duration", "1", "--wait", "5000"], { capture: true });
        await run(["sim", "--device", qa.device, "tap", "--label", "Delete", "--wait", "5000", "--stable", "200"], { capture: true });
        let confirmation = false;
        for (let attempt = 0; attempt < 30 && !confirmation; attempt++) {
          const tree = await run(["sim", "--device", qa.device, "describe"], { capture: true });
          confirmation = tree.stdout.includes(`Delete /${copied}?`);
          if (!confirmation) await Bun.sleep(100);
        }
        assert(confirmation, "Confirm deletion of exactly the run-owned copy");
        await run(["sim", "--device", qa.device, "tap", "--label", "Delete", "--wait", "5000", "--stable", "200"], { capture: true });
      } else await call("ox.skill.delete", { name: copied });
      await run(["ox", "--host", qa.values.host, "--chat", qa.values.chat, "chat", "open", "--json"], { capture: true });
      await run(["ox", "--host", qa.values.host, "chat", "new", "--temporary", "--provider", "mock", "--model", "mock", "--json"], { capture: true });
      const fresh = await run(["ox", "--host", qa.values.host, "chat", "inspect", "--json"], { capture: true });
      const freshID = JSON.parse(fresh.stdout).id as string;
      let removed = false;
      for (let attempt = 0; attempt < 30 && !removed; attempt++) {
        const remaining = await call("ox.fs.list", { path: "skills", options: { limit: 100 } }, freshID);
        removed = !remaining.items.some((item: { path: string }) => item.path === `skills/${copied}`);
        if (!removed) await Bun.sleep(100);
      }
      assert(removed, "Run-owned copy must leave the live catalog");
      checks.push("run-owned copy removed from the live catalog without changing deletion policy");
    }
    await writeFile(join(directory, "report.json"), JSON.stringify({ device: qa.device, checks, copied, cleaned: created }, null, 2) + "\n", { mode: 0o600 });
  } finally { release(); }
}
console.log(`PASS bundled skills E2E (${checks.length} checks including cleanup)`);

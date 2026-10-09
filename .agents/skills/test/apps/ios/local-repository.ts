import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/local-repository.ts --device ox-N --host <ws-url> --chat <saved-QA-chat> --bundle <bundle-id> --domain <qa-draft-domain> [--output /tmp/directory]\nRequires enabled Local and an existing empty run-owned qa- web draft. Temporarily disables Local, verifies mutation refusals and unchanged source/configuration/Git bytes, then reenables and writes identical source. Restores enablement; creates no drafts or commits.",
  options: { host: { type: "string" }, chat: { type: "string" }, bundle: { type: "string" }, domain: { type: "string" }, output: { type: "string" } },
});
const { host, chat, bundle, domain } = qa.values;
assert(host && chat && bundle && domain?.startsWith("qa-"), "Pass an explicit Host, saved QA chat, bundle, and run-owned qa- domain");
assert.equal(Number(new URL(host).port), qa.debugPort);
const directory = resolve(qa.values.output ?? `/tmp/ox-local-repository-${Date.now()}`);
assert(directory !== ROOT && !directory.startsWith(ROOT + "/"), "Keep evidence outside the repository");
const path = `services/web/${domain}/actions.js`;
const checks: string[] = [];
let originalEnabled: boolean | undefined;

async function call(name: string, args: Record<string, unknown> = {}) {
  const result = await run(["ox", "--host", host!, "--chat", chat!, "vm", "call", name, "--args",
    JSON.stringify({ ...args, purpose: "Verify disabled Local mutation safety" }), "--json"], { capture: true });
  return JSON.parse(result.stdout).value;
}
async function enabled(value: boolean) {
  await call("ox.repository.enable", { repository: "local", enabled: value });
  assert.equal((await call("ox.repository.list")).repositories.find((row: { id: string }) => row.id === "local").enabled, value);
}
async function refused(name: string, args: Record<string, unknown>) {
  const result = await run(["ox", "--host", host!, "--chat", chat!, "vm", "call", name, "--args",
    JSON.stringify({ ...args, purpose: "Verify disabled Local mutation safety" }), "--json"], { capture: true, allowFailure: true });
  assert.notEqual(result.code, 0, `${name} accepted a disabled Local mutation`);
  assert.match(result.stderr + result.stdout, /Local repository is disabled.*Enable Local in Settings > Repositories.*This operation made no changes/s);
  checks.push(`${name}: actionable disabled-Local refusal`);
}
async function fingerprint(root: string): Promise<Record<string, string>> {
  const files: Record<string, string> = {};
  async function visit(directory: string) {
    for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) files[relative(root, path)] = createHash("sha256").update(await readFile(path)).digest("hex");
      else throw new Error(`Unsupported snapshot entry: ${path}`);
    }
  }
  await visit(root);
  return files;
}
async function snapshot(name: string) {
  const target = join(directory, name);
  await mkdir(target, { recursive: true });
  for (const path of ["service-repositories/local", "service-repositories.json"]) {
    await run(["sim", "--device", qa.device, "file", "pull", bundle!, `Library/Application Support/${path}`, "--dest", target], { capture: true });
  }
  return fingerprint(target);
}

assert(await requireSimulator(qa.device), "Boot the reserved simulator before testing");
const release = claimSimulator(qa.device);
try {
  await mkdir(directory, { recursive: true });
  const inspected = await run(["ox", "--host", host, "--chat", chat, "chat", "inspect", "--json"], { capture: true });
  const state = JSON.parse(inspected.stdout);
  assert.equal(state.isBusy, false, "Use an idle saved QA chat");
  assert(JSON.stringify(state.messages).includes("QA Local repository enablement regression"), "Use a dedicated regression chat");
  const session = await run(["ox", "--host", host, "--chat", chat, "vm", "inspect", "--json"], { capture: true });
  assert.equal(JSON.parse(session.stdout).value.session.temporary, false);
  const local = (await call("ox.repository.list")).repositories.find((row: { id: string }) => row.id === "local");
  assert(local?.enabled && local.state === "ready", "Prepare enabled Local before testing");
  originalEnabled = local.enabled;
  const guide = (await call("ox.fs.read", { path: "skills/evolve/SKILL.md" })).text as string;
  assert.match(guide, /inspect `ox.repository.list`.*Enable Local and continue.*explicitly requests or confirms enablement.*ox.repository.enable.*enabled and ready/s);
  checks.push("bundled authoring guidance requires a user enablement handoff");
  const source = (await call("ox.fs.read", { path })).text as string;
  assert.equal(source.trim(), "window.ox.install(() => {});", "Use only an empty run-owned draft");
  const status = await call("ox.repository.git.status");
  await enabled(false);
  const before = await snapshot("before");
  for (const [name, args] of [
    ["ox.service.create", { kind: "web", domain: `${domain}-blocked` }],
    ["ox.service.create", { kind: "api", domain: `${domain}-blocked-api` }],
    ["ox.service.copy", { domain: "news.ycombinator.com" }],
    ["ox.fs.write", { path, content: source }],
    ["ox.fs.edit", { path, edits: [{ oldText: source.trim(), newText: source.trim() }] }],
    ["ox.repository.git.checkout", { commitHash: "latest" }],
    ["ox.repository.git.commit", { message: "QA forbidden save" }],
    ["ox.repository.git.revert", { commitHash: status.commitHash, message: "QA forbidden revert" }],
    ["ox.repository.git.restore", { path }],
    ["ox.repository.resolve", { service: "news.ycombinator.com", repository: "local" }],
  ] as const) await refused(name, args);
  assert.deepEqual(await snapshot("after"), before, "Rejected operations changed Local source, Git, or repository configuration");
  assert.deepEqual(await call("ox.repository.git.status"), status, "Rejected operations changed Git status");
  checks.push("all Local source, Git, and configuration bytes unchanged");
  await enabled(true);
  await call("ox.fs.write", { path, content: source });
  assert.equal((await call("ox.fs.read", { path })).text, source);
  assert.deepEqual(await call("ox.repository.git.status"), status);
  checks.push("same source write succeeds after explicit enablement without changing existing work");
} finally {
  try {
    if (originalEnabled !== undefined) await enabled(originalEnabled);
    await writeFile(join(directory, "report.json"), JSON.stringify({ device: qa.device, chat, domain, checks }, null, 2) + "\n", { mode: 0o600 });
  } finally { release(); }
}
console.log(`PASS Local repository E2E (${checks.length} checks); evidence: ${directory}`);

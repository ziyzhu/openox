import { strict as assert } from "node:assert";
import { mkdtemp, mkdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../setup/scripts/simulator.ts";
import { iosTarget } from "../../../setup/scripts/ios.ts";
import { waitForHost } from "./host.ts";

const config = qaCommand({
  usage: "Usage: bun .agents/skills/test/apps/ios/settings.ts --device ox-N --host <ws-url> --app <Ox.app> [--output <directory>]\nRequires an idle, booted, reserved simulator with Host access already enabled. Exercises settings through ox, relaunches the installed build, and restores preferences and the previous saved conversation.",
  options: { host: { type: "string" }, app: { type: "string" }, output: { type: "string" } },
});
if (!config.values.device || !config.values.host || !config.values.app) throw new Error("Pass --device, --host, and --app explicitly");
const ios = iosTarget(config.device);
const endpoint = new URL(config.values.host);
if (!["ws:", "wss:"].includes(endpoint.protocol) || Number(endpoint.port) !== config.debugPort) {
  throw new Error(`Use the selected simulator's Host on port ${config.debugPort}`);
}
const app = await realpath(resolve(config.values.app));
const localConfig = await Bun.file(join(ROOT, "apps/ios/Local.xcconfig")).text().catch(() => "");
const bundle = /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(localConfig)?.[1] ?? "ai.openox.local";
const directory = resolve(config.values.output ?? tmpdir());
await mkdir(directory, { recursive: true });
const parent = await realpath(directory);
const fromRoot = relative(await realpath(ROOT), parent);
if (!fromRoot || (!fromRoot.startsWith("../") && !isAbsolute(fromRoot))) throw new Error("Keep evidence outside the repository");
const evidence = await mkdtemp(join(parent, "openox-settings-"));
console.log(`Settings E2E ${config.device}; evidence: ${evidence}`);

type Selection = { selection: string };
type Repository = { id: string; enabled: boolean; state: string };
type DefaultModel = { configured: boolean; provider: { id: string }; model: { id: string }; thinkingLevel: string | null; authentication: { status: string } };
let conversation: string | undefined;
let previousConversation: string | undefined;
let baseline: { language: Selection; repository: Repository; defaultModel: DefaultModel } | undefined;
const results: unknown[] = [];

async function ox(...args: string[]): Promise<any> {
  const result = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint.href, ...args, "--json"], { capture: true });
  return JSON.parse(result.stdout);
}

async function call(name: string, args: Record<string, unknown> = {}): Promise<any> {
  assert.ok(conversation, "A temporary QA conversation is required");
  const result = await ox("--conversation", conversation!, "vm", "call", name, "--args", JSON.stringify({ ...args, purpose: "Verify settings controls" }));
  results.push({ name, args, value: result.value });
  return result.value;
}

async function rejected(name: string, args: Record<string, unknown>, message: string): Promise<void> {
  const result = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint.href, "--conversation", conversation!, "vm", "call", name,
    "--args", JSON.stringify({ ...args, purpose: "Verify invalid settings" }), "--json"], { capture: true, allowFailure: true });
  assert.notEqual(result.code, 0, `${name} accepted invalid arguments`);
  assert.ok((result.stderr + result.stdout).includes(message), `${name} did not report the expected validation error`);
  results.push({ name, args, rejected: true });
}

async function waitForSavedDefaultModel(): Promise<void> {
  const destination = join(evidence, "preferences");
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    await ios.pull(bundle, `Library/Preferences/${bundle}.plist`, destination);
    const stored = await run(["plutil", "-extract", "llm\\.defaultModel", "raw", "-o", "-", join(destination, `${bundle}.plist`)], { capture: true, allowFailure: true });
    if (stored.code === 0) {
      const selection = JSON.parse(Buffer.from(stored.stdout.trim(), "base64").toString());
      if (selection.providerID === "mock" && selection.modelID === "mock-text-only") return;
    }
    await Bun.sleep(200);
  }
  throw new Error("Default model has not reached on-device preferences; do not terminate before persistence");
}

async function newConversation(): Promise<void> {
  const created = await ox("conversation", "new", "--temporary", "--provider", "mock", "--model", "mock");
  assert.equal(typeof created.conversationId, "string");
  conversation = created.conversationId;
}

const release = claimSimulator(config.device);
try {
  assert.ok(await requireSimulator(config.device), "Boot the reserved simulator before testing");
  await ox("host", "describe", "--timeout", "3000");
  const active = await ox("conversation", "list", "--active");
  previousConversation = active[0]?.id;
  if (previousConversation) {
    const snapshot = await ox("--conversation", previousConversation, "conversation", "inspect");
    assert.equal(snapshot.isBusy, false, "Do not interrupt a running conversation");
    const inspected = await ox("--conversation", previousConversation, "vm", "inspect");
    assert.equal(inspected.value.session.temporary, false, "Preserve or close the temporary conversation before testing");
  }
  for (const name of ["ox.app.setLanguage", "ox.repository.enable", "ox.app.setDefaultModel", "ox.conversation.setModel", "ox.conversation.model", "ox.conversation.rename", "ox.repository.list"]) {
    const help = await ox("vm", "help", name);
    assert.equal(help.name, name);
  }
  await newConversation();
  const language = await call("ox.app.language");
  const aliases = await ox("--conversation", conversation!, "vm", "eval", "--script", `return [
    [ox.app.model, ox.conversation.model],
    [ox.app.setModel, ox.conversation.setModel],
    [ox.app.renameConversation, ox.conversation.rename],
    [ox.app.repositories, ox.repository.list],
  ].every(([previous, current]) => previous === current && previous.help() === current.help())
    && !["model", "setModel", "renameChat", "repositories"].some(name => Object.keys(ox.app).includes(name));`);
  assert.equal(aliases.value, true, "Old helpers must remain hidden aliases with current validation and help");
  const repositories = await call("ox.repository.list");
  const local = repositories.repositories.find((candidate: Repository) => candidate.id === "local");
  assert.ok(local && local.state === "ready" && local.enabled, "A prepared, enabled Local repository is required");
  const repository = repositories.repositories.find((candidate: Repository) => candidate.id === "bundled");
  assert.ok(repository && repository.state === "ready", "A prepared Bundled repository is required");
  const defaultModel = await call("ox.app.defaultModel") as DefaultModel;
  assert.ok(!defaultModel.configured || ["ready", "notRequired"].includes(defaultModel.authentication.status), "The original default must be available for restoration");
  baseline = { language, repository, defaultModel };
  await writeFile(join(evidence, "baseline.json"), JSON.stringify(baseline, null, 2), { mode: 0o600 });
  for (const [reader, setter, choices] of [
    ["ox.app.language", "ox.app.setLanguage", ["system", "en", "zh-Hans"]],
  ] as const) {
    for (const selection of choices) {
      const before = await call(reader);
      const changed = await call(setter, { selection });
      assert.equal(changed.selection, selection);
      assert.equal(changed.changed, before.selection !== selection);
      assert.equal((await call(reader)).selection, selection);
      assert.equal((await call(setter, { selection })).changed, false);
    }
    await rejected(setter, { selection: "unsupported" }, "selection");
    await rejected(setter, {}, "selection");
    await rejected(setter, { selection: choices[0], unexpected: true }, "unexpected");
  }
  const providers = await call("ox.provider.list") as Array<{ id: string; api: string; source: string }>;
  assert.ok(providers.length > 0 && providers.every(provider => provider.api !== "web" && provider.source !== "web-service"), "Websites must remain services, never model providers");
  for (const provider of ["claude-web", "qwen-web", "kimi-web", "grok-web", "web:gemini.google.com"]) {
    await rejected("ox.conversation.setModel", { selection: { provider, model: "website-default" } }, "existing provider");
  }
  const selection = { provider: "mock", model: "mock-text-only" };
  const idle = await call("ox.conversation.setModel", { selection });
  assert.equal(idle.status, "applied");
  assert.equal(idle.changed, true);
  assert.equal((await call("ox.conversation.model")).model.id, selection.model);
  assert.equal((await call("ox.conversation.setModel", { selection })).changed, false);
  await call("ox.app.setDefaultModel", { selection: null });
  assert.equal((await call("ox.app.defaultModel")).configured, false);
  assert.equal((await call("ox.app.setDefaultModel", { selection: null })).changed, false);
  assert.equal((await call("ox.app.setDefaultModel", { selection })).changed, true);
  assert.equal((await call("ox.app.setDefaultModel", { selection })).changed, false);
  for (const setter of ["ox.app.setDefaultModel", "ox.conversation.setModel"]) {
    await rejected(setter, {}, "selection");
    await rejected(setter, { selection: { provider: "missing-model-qa", model: "mock" } }, "existing provider");
    await rejected(setter, { selection: { provider: "mock", model: "missing-model-qa" } }, "available model");
    await rejected(setter, { selection: { ...selection, thinkingLevel: "high" } }, "thinking level");
    await rejected(setter, { selection: { ...selection, unexpected: true } }, "unexpected");
  }
  await rejected("ox.conversation.setModel", { selection: null }, "selection");
  await rejected("ox.conversation.rename", { title: "" }, "title");
  await rejected("ox.conversation.rename", { title: "x".repeat(61) }, "title");
  assert.equal((await call("ox.app.defaultModel")).model.id, selection.model);
  assert.equal((await call("ox.conversation.model")).model.id, selection.model);
  await rejected("ox.repository.enable", { repository: "local", enabled: "false" }, "enabled");
  await rejected("ox.repository.enable", { repository: "missing-settings-qa", enabled: false }, "existing repository ID");
  await rejected("ox.repository.enable", { repository: "local", enabled: false }, "always enabled");
  const enabled = !repository.enabled;
  const updated = await call("ox.repository.enable", { repository: repository.id, enabled });
  assert.equal(updated.enabled, enabled);
  assert.equal(updated.changed, true);
  assert.equal((await call("ox.repository.enable", { repository: repository.id, enabled })).changed, false);
  const after = await call("ox.repository.list");
  assert.equal(after.repositories.find((candidate: Repository) => candidate.id === repository.id).enabled, enabled);
  for (const candidate of repositories.repositories as Repository[]) {
    if (candidate.id !== repository.id) assert.equal(after.repositories.find((row: Repository) => row.id === candidate.id)?.enabled, candidate.enabled);
  }
  await ios.screenshot(join(evidence, "before-relaunch.png"));
  await waitForSavedDefaultModel();
  conversation = undefined;
  await ios.launch(bundle, app, { OX_DEBUG_ENDPOINT: config.debugEndpoint, OX_HOST_LOOPBACK: endpoint.hostname === "127.0.0.1" ? "1" : "0" });
  await ios.wait({ id: "conversation.temporaryToggle" }, { timeout: 30_000, stable: 1000 });
  await waitForHost(endpoint.href, () => ox("host", "describe", "--timeout", "1000"));
  await newConversation();
  assert.equal((await call("ox.app.defaultModel")).model.id, "mock-text-only");
  assert.equal((await call("ox.app.language")).selection, "zh-Hans");
  assert.equal((await call("ox.repository.list")).repositories.find((candidate: Repository) => candidate.id === repository.id).enabled, enabled);
  console.log("PASS settings contracts, supported selections, validation, no-op results, repository isolation, and relaunch persistence");
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  if (baseline) {
    if (!conversation) await newConversation().catch(error => { console.error(`Cleanup conversation unavailable: ${error}`); process.exitCode = 1; });
    for (const [name, args, reader, expected] of [
      ["ox.app.setLanguage", { selection: baseline.language.selection }, "ox.app.language", baseline.language.selection],
      ["ox.app.setDefaultModel", { selection: baseline.defaultModel.configured ? { provider: baseline.defaultModel.provider.id, model: baseline.defaultModel.model.id, thinkingLevel: baseline.defaultModel.thinkingLevel } : null }, "ox.app.defaultModel", baseline.defaultModel.configured],
      ["ox.repository.enable", { repository: baseline.repository.id, enabled: baseline.repository.enabled }, "ox.repository.list", baseline.repository.enabled],
    ] as const) {
      try {
        await call(name, args);
        const restored = await call(reader);
        assert.equal(reader === "ox.repository.list" ? restored.repositories.find((row: Repository) => row.id === baseline!.repository.id).enabled : reader === "ox.app.defaultModel" ? restored.configured : restored.selection, expected);
        if (reader === "ox.app.defaultModel" && baseline.defaultModel.configured) {
          assert.equal(restored.provider.id, baseline.defaultModel.provider.id);
          assert.equal(restored.model.id, baseline.defaultModel.model.id);
          assert.equal(restored.thinkingLevel, baseline.defaultModel.thinkingLevel);
        }
      } catch (error) { console.error(`Settings restoration failed: ${error}`); process.exitCode = 1; }
    }
  }
  if (conversation) {
    const restore = previousConversation ? ["--conversation", previousConversation, "conversation", "open"] : ["conversation", "new", "--temporary"];
    await ox(...restore).catch(error => { console.error(`Conversation restoration failed: ${error}`); process.exitCode = 1; });
  }
  try { await writeFile(join(evidence, "results.json"), JSON.stringify(results, null, 2), { mode: 0o600 }); }
  finally { release(); }
}

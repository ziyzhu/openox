import { strict as assert } from "node:assert";
import { mkdtemp, mkdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const config = qaCommand({
  usage: "Usage: bun .agents/skills/test/apps/ios/settings.ts --device ox-N --host <ws-url> --app <Ox.app> [--output <directory>]\nRequires an idle, booted, reserved simulator with Host access already enabled. Exercises settings through ox, relaunches the installed build, and restores preferences and the previous saved chat.",
  options: { host: { type: "string" }, app: { type: "string" }, output: { type: "string" } },
});
if (!config.values.device || !config.values.host || !config.values.app) throw new Error("Pass --device, --host, and --app explicitly");
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
let chat: string | undefined;
let previousChat: string | undefined;
let baseline: { language: Selection; theme: Selection; repository: Repository; defaultModel: DefaultModel } | undefined;
const results: unknown[] = [];

async function ox(...args: string[]): Promise<any> {
  const result = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint.href, ...args, "--json"], { capture: true });
  return JSON.parse(result.stdout);
}

async function call(name: string, args: Record<string, unknown> = {}): Promise<any> {
  assert.ok(chat, "A temporary QA chat is required");
  const result = await ox("--chat", chat!, "vm", "call", name, "--args", JSON.stringify({ ...args, purpose: "Verify settings controls" }));
  results.push({ name, args, value: result.value });
  return result.value;
}

async function rejected(name: string, args: Record<string, unknown>, message: string): Promise<void> {
  const result = await run(["bun", "apps/cli/src/ox.ts", "--host", endpoint.href, "--chat", chat!, "vm", "call", name,
    "--args", JSON.stringify({ ...args, purpose: "Verify invalid settings" }), "--json"], { capture: true, allowFailure: true });
  assert.notEqual(result.code, 0, `${name} accepted invalid arguments`);
  assert.ok((result.stderr + result.stdout).includes(message), `${name} did not report the expected validation error`);
  results.push({ name, args, rejected: true });
}

async function waitForHost(): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try { await ox("host", "describe", "--timeout", "1000"); return; } catch {}
    await Bun.sleep(200);
  }
  throw new Error(`Host unavailable at ${endpoint.href}`);
}

async function newChat(): Promise<void> {
  const created = await ox("chat", "new", "--temporary", "--provider", "mock", "--model", "mock");
  assert.equal(typeof created.chatId, "string");
  chat = created.chatId;
}

const release = claimSimulator(config.device);
try {
  assert.ok(await requireSimulator(config.device), "Boot the reserved simulator before testing");
  await ox("host", "describe", "--timeout", "3000");
  const active = await ox("chat", "list", "--active");
  previousChat = active[0]?.id;
  if (previousChat) {
    const snapshot = await ox("--chat", previousChat, "chat", "inspect");
    assert.equal(snapshot.isBusy, false, "Do not interrupt a running chat");
    const inspected = await ox("--chat", previousChat, "vm", "inspect");
    assert.equal(inspected.value.session.temporary, false, "Preserve or close the temporary chat before testing");
  }
  for (const name of ["ox.app.setLanguage", "ox.app.setTheme", "ox.repository.enable", "ox.app.setDefaultModel", "ox.app.setModel"]) {
    const help = await ox("vm", "help", name);
    assert.equal(help.name, name);
  }
  await newChat();
  const language = await call("ox.app.language");
  const theme = await call("ox.app.theme");
  const repositories = await call("ox.app.repositories");
  const repository = repositories.repositories.find((candidate: Repository) => candidate.id === "local");
  assert.ok(repository && repository.state === "ready", "A prepared Local repository is required");
  const defaultModel = await call("ox.app.defaultModel") as DefaultModel;
  assert.ok(!defaultModel.configured || ["ready", "notRequired"].includes(defaultModel.authentication.status), "The original default must be available for restoration");
  baseline = { language, theme, repository, defaultModel };
  await writeFile(join(evidence, "baseline.json"), JSON.stringify(baseline, null, 2), { mode: 0o600 });
  for (const [reader, setter, choices] of [
    ["ox.app.language", "ox.app.setLanguage", ["system", "en", "zh-Hans"]],
    ["ox.app.theme", "ox.app.setTheme", ["creatorPick", "light", "dark"]],
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
  const selection = { provider: "mock", model: "mock-text-only" };
  const idle = await call("ox.app.setModel", { selection });
  assert.equal(idle.status, "applied");
  assert.equal(idle.changed, true);
  assert.equal((await call("ox.app.model")).model.id, selection.model);
  assert.equal((await call("ox.app.setModel", { selection })).changed, false);
  await call("ox.app.setDefaultModel", { selection: null });
  assert.equal((await call("ox.app.defaultModel")).configured, false);
  assert.equal((await call("ox.app.setDefaultModel", { selection: null })).changed, false);
  assert.equal((await call("ox.app.setDefaultModel", { selection })).changed, true);
  assert.equal((await call("ox.app.setDefaultModel", { selection })).changed, false);
  for (const setter of ["ox.app.setDefaultModel", "ox.app.setModel"]) {
    await rejected(setter, {}, "selection");
    await rejected(setter, { selection: { provider: "missing-model-qa", model: "mock" } }, "existing provider");
    await rejected(setter, { selection: { provider: "mock", model: "missing-model-qa" } }, "available model");
    await rejected(setter, { selection: { ...selection, thinkingLevel: "high" } }, "thinking level");
    await rejected(setter, { selection: { ...selection, unexpected: true } }, "unexpected");
  }
  await rejected("ox.app.setModel", { selection: null }, "selection");
  assert.equal((await call("ox.app.defaultModel")).model.id, selection.model);
  assert.equal((await call("ox.app.model")).model.id, selection.model);
  await rejected("ox.repository.enable", { repository: "local", enabled: "false" }, "enabled");
  await rejected("ox.repository.enable", { repository: "missing-settings-qa", enabled: false }, "existing repository ID");
  const enabled = !repository.enabled;
  const updated = await call("ox.repository.enable", { repository: repository.id, enabled });
  assert.equal(updated.enabled, enabled);
  assert.equal(updated.changed, true);
  assert.equal((await call("ox.repository.enable", { repository: repository.id, enabled })).changed, false);
  const after = await call("ox.app.repositories");
  assert.equal(after.repositories.find((candidate: Repository) => candidate.id === repository.id).enabled, enabled);
  for (const candidate of repositories.repositories as Repository[]) {
    if (candidate.id !== repository.id) assert.equal(after.repositories.find((row: Repository) => row.id === candidate.id)?.enabled, candidate.enabled);
  }
  await run(["sim", "--device", config.device, "screenshot", "--out", join(evidence, "before-relaunch.png")]);
  chat = undefined;
  await run(["sim", "--device", config.device, "run", bundle, "--app", app, "--env", `OX_DEBUG_ENDPOINT=${config.debugEndpoint}`]);
  await run(["sim", "--device", config.device, "wait", "--id", "chat.temporaryToggle", "--timeout", "30000", "--stable", "1000"]);
  await waitForHost();
  await newChat();
  assert.equal((await call("ox.app.defaultModel")).model.id, "mock-text-only");
  assert.equal((await call("ox.app.language")).selection, "zh-Hans");
  assert.equal((await call("ox.app.theme")).selection, "dark");
  assert.equal((await call("ox.app.repositories")).repositories.find((candidate: Repository) => candidate.id === repository.id).enabled, enabled);
  console.log("PASS settings contracts, supported selections, validation, no-op results, repository isolation, and relaunch persistence");
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  if (baseline) {
    if (!chat) await newChat().catch(error => { console.error(`Cleanup chat unavailable: ${error}`); process.exitCode = 1; });
    for (const [name, args, reader, expected] of [
      ["ox.app.setLanguage", { selection: baseline.language.selection }, "ox.app.language", baseline.language.selection],
      ["ox.app.setTheme", { selection: baseline.theme.selection }, "ox.app.theme", baseline.theme.selection],
      ["ox.app.setDefaultModel", { selection: baseline.defaultModel.configured ? { provider: baseline.defaultModel.provider.id, model: baseline.defaultModel.model.id, thinkingLevel: baseline.defaultModel.thinkingLevel } : null }, "ox.app.defaultModel", baseline.defaultModel.configured],
      ["ox.repository.enable", { repository: baseline.repository.id, enabled: baseline.repository.enabled }, "ox.app.repositories", baseline.repository.enabled],
    ] as const) {
      try {
        await call(name, args);
        const restored = await call(reader);
        assert.equal(reader === "ox.app.repositories" ? restored.repositories.find((row: Repository) => row.id === "local").enabled : reader === "ox.app.defaultModel" ? restored.configured : restored.selection, expected);
        if (reader === "ox.app.defaultModel" && baseline.defaultModel.configured) {
          assert.equal(restored.provider.id, baseline.defaultModel.provider.id);
          assert.equal(restored.model.id, baseline.defaultModel.model.id);
          assert.equal(restored.thinkingLevel, baseline.defaultModel.thinkingLevel);
        }
      } catch (error) { console.error(`Settings restoration failed: ${error}`); process.exitCode = 1; }
    }
  }
  if (chat) {
    const restore = previousChat ? ["--chat", previousChat, "chat", "open"] : ["chat", "new", "--temporary"];
    await ox(...restore).catch(error => { console.error(`Chat restoration failed: ${error}`); process.exitCode = 1; });
  }
  try { await writeFile(join(evidence, "results.json"), JSON.stringify(results, null, 2), { mode: 0o600 }); }
  finally { release(); }
}

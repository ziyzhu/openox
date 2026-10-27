import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../../../../lib.ts";

async function template(value: unknown, args: string[] = ["--validate"], env: Record<string, string> = {}) {
  const directory = await mkdtemp(join(tmpdir(), "openox-template-cli-"));
  try {
    const path = join(directory, "template.json");
    await writeFile(path, JSON.stringify(value));
    await writeFile(join(directory, "file.txt"), "Template file\n");
    await symlink("file.txt", join(directory, "linked.txt"));
    const child = Bun.spawn([process.execPath, "run", "sim:launch", "--template", path, ...args], {
      cwd: ROOT, env: { ...Bun.env, ...env }, stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    return { code, stdout, stderr };
  } finally { await rm(directory, { recursive: true, force: true }); }
}

test("internal template materializer creates dormant current Profiles in a subprocess without native setup", async () => {
  const directory = await mkdtemp(join(tmpdir(), "openox-template-materialize-"));
  try {
    const input = join(directory, "input.json");
    await writeFile(input, JSON.stringify({ version: 1, profiles: [{ id: "qa", name: "Desktop", memory: "Offline memory",
      files: [{ path: "notes/shared.txt", content: { text: "Shared bytes" } }],
      conversations: [{ id: "saved", title: "Saved offline", model: { provider: "mock", model: "mock", thinking: "high" }, favorite: true,
        files: [{ id: "note", name: "note.txt", content: { text: "Attachment bytes" } }],
        messages: [{ role: "user", text: "Read my note", attachments: ["note"] }, { role: "assistant", text: "Saved", reasoning: "No model call" }] }] }] }));
    const program = `
      import { parseTemplate, prepareTemplate } from "./.agents/skills/setup/scripts/template-schema.ts";
      import { materializeProfiles } from "./.agents/skills/setup/scripts/template-profile.ts";
      const input = ${JSON.stringify(input)};
      const prepared = await prepareTemplate(parseTemplate(await Bun.file(input).json()), input, crypto.randomUUID().toUpperCase());
      console.log(JSON.stringify(await materializeProfiles(prepared, ${JSON.stringify(directory)})));
    `;
    const child = Bun.spawn([process.execPath, "-e", program], {
      cwd: ROOT, stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    expect(stderr).not.toContain("xcrun");
    expect(code, stderr).toBe(0);
    const result = JSON.parse(stdout);
    const profile = result.profiles.qa;
    const config = await Bun.file(join(profile.state, "profile.json")).json();
    expect(config.id).toBe(profile.id);
    expect(config.contentDirectory).toBe(profile.name);
    expect(config.version).toBeTruthy();
    expect(await Bun.file(join(profile.content, "MEMORY.md")).text()).toBe("Offline memory");
    expect(await Bun.file(join(profile.content, "notes/shared.txt")).text()).toBe("Shared bytes");
    expect(await Bun.file(join(profile.content, `conversations/${profile.conversations.saved}/note.txt`)).text()).toBe("Attachment bytes");
    const database = new Database(join(profile.state, "state.sqlite"), { readonly: true });
    try {
      expect(database.query("PRAGMA integrity_check").get()).toEqual({ integrity_check: "ok" });
      expect(database.query("SELECT COUNT(*) AS count FROM tasks").get()).toEqual({ count: 0 });
      expect(database.query("SELECT COUNT(*) AS count FROM submissions").get()).toEqual({ count: 0 });
    } finally { database.close(); }
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("template CLI does not expose internal materialization", async () => {
  const help = await template({ version: 1 }, ["--help"]);
  expect(help.code).toBe(0);
  expect(help.stdout).not.toContain("--materialize");
  const result = await template({ version: 1 }, ["--materialize"]);
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("Unknown option '--materialize'");
  expect(result.stderr).not.toContain("xcrun");
});

const basic = {
  version: 1,
  settings: { language: "en", defaultModel: { provider: "mock", model: "mock" } },
  userDefaults: { app: { set: { count: 3, enabled: true, bytes: { data: "YWJj" }, list: ["a", 2], nested: { dictionary: { value: "x" } }, date: { date: "2026-01-01T00:00:00Z" } }, remove: ["old"] } },
  profiles: [{ id: "qa", name: "QA", files: [{ path: "notes/file.txt", content: { fromFile: "file.txt" } }], conversations: [{ id: "conversation", title: "Conversation", messages: [{ role: "user", text: "Hello" }, { role: "assistant", text: "Hi", reasoning: "A greeting." }] }] }],
  selection: { profile: "qa", conversation: "conversation" },
};

test("template CLI validates complete JSON and relative external inputs without iOS", async () => {
  const result = await template(basic);
  expect(result.code).toBe(0);
  expect(result.stdout).toContain("VALID template and external inputs");
});

test("template CLI rejects unsupported state and broken references before simulator access", async () => {
  const invalid = [
    { ...basic, version: 2 },
    { ...basic, logs: [] },
    { ...basic, settings: { language: "missing" } },
    { ...basic, selection: { profile: "missing" } },
    { ...basic, profiles: [{ id: "qa", name: "../escape" }] },
    { ...basic, profiles: [{ id: "qa", name: "QA", files: [{ path: "../escape", content: { text: "x" } }] }] },
    { ...basic, profiles: [{ id: "qa", name: "QA", conversations: [{ id: "conversation", title: "Conversation", messages: [{ role: "user", text: "Hello", attachments: ["missing"] }] }] }] },
    { ...basic, userDefaults: { app: { set: { same: 1 }, remove: ["same"] } } },
    { ...basic, userDefaults: { app: { set: { "app.language": "en" } } } },
    { ...basic, userDefaults: { app: { set: { date: { date: "2026-02-30T00:00:00Z" } } } } },
    { ...basic, userDefaults: { app: { set: { data: { data: "invalid base64" } } } } },
    { version: 1, storage: [{ domain: "caches", path: "snapshot", from: "linked.txt", provenance: { build: "1", storageVersion: "1" } }] },
    { ...basic, storage: [{ domain: "applicationSupport", path: "logs.jsonl", from: "file.txt", provenance: { build: "1", storageVersion: "1" } }] },
  ];
  for (const input of invalid) {
    const result = await template(input);
    expect(result.code).toBe(1);
    expect(result.stderr).not.toContain("xcrun");
  }
});

test("template CLI requires explicit target and write authorization", async () => {
  expect((await template(basic, [])).stderr).toContain("--device");
  expect((await template(basic, ["--device", "ox-6"])).stderr).toContain("QA device");
  const credentials = { version: 1, keychain: { providers: [{ provider: "openai", secret: { env: "OX_TEMPLATE_E2E_SECRET" } }] } };
  const env = { OX_TEMPLATE_E2E_SECRET: "private-template-e2e-value" };
  const missing = await template(credentials, ["--validate"], { OX_TEMPLATE_E2E_SECRET: "" });
  expect(missing.code).toBe(1);
  expect(missing.stderr).toContain("secret is missing");
  const denied = await template(credentials, ["--device", "ox-3"], env);
  expect(denied.stderr).toContain("--allow-keychain");
  expect(denied.stderr + denied.stdout).not.toContain(env.OX_TEMPLATE_E2E_SECRET);
  const raw = await template({ version: 1, userDefaults: { app: { set: { "storage.activeProfile": "example" } } } }, ["--device", "ox-3"]);
  expect(raw.stderr).toContain("--allow-storage-replay");
  const invalidSecret = await template({ version: 1, keychain: { secrets: [{ key: "qa", name: "QA", secret: { env: "OX_TEMPLATE_E2E_SECRET" } }] } }, ["--validate"], env);
  expect(invalidSecret.code).toBe(1);
  expect(invalidSecret.stderr).not.toContain(env.OX_TEMPLATE_E2E_SECRET);
});

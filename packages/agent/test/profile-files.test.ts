import { afterEach, beforeEach, expect, test } from "bun:test";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import { Harness, createRegistry } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ProfileFiles, ProfileFile, canonical } from "../src/core/profile-files";
import { profileEnv } from "../src/core/profile-env";
import { backend } from "./sqlite-backend";
import { openOxAgentSession, installOxProfile, type NormalizedProfileDraft, type ArtifactFiles } from "../src/index";
import { artifactPath } from "../src/core/artifacts";
import { mkdtemp, mkdir, open, rm, readFile, writeFile } from "node:fs/promises";
import { constants } from "node:fs";

let harness: Harness;
let files: ProfileFiles;
let db: ReturnType<typeof backend>["db"];
beforeEach(async () => {
  db = backend().db;
  harness = await Harness.open(await SqliteStorage.open(db), { registry: createRegistry(), models: createModels() }, BACKGROUND_CONTEXT);
  files = new ProfileFiles(harness, db, "fixture-profile", async () => crypto.randomUUID()); await files.initialize();
});
afterEach(async () => { await files.flush(); await harness.close(BACKGROUND_CONTEXT); });

test("text, identity, Unicode and atomic multi-edit belong to Session documents", async () => {
  await files.write("MEMORY.md", "你好 😀\nleft\nright\n");
  await files.edit("MEMORY.md", [{ oldText: "left", newText: "LEFT" }, { oldText: "right", newText: "RIGHT" }]);
  expect(await files.read("MEMORY.md")).toBe("你好 😀\nLEFT\nRIGHT\n");
  expect((await harness.snapshot(ProfileFile, "MEMORY.md", BACKGROUND_CONTEXT))?.text).toContain("LEFT");
  await expect(new ProfileFiles(harness, db, "another-profile", async () => crypto.randomUUID()).initialize()).rejects.toThrow("identity");
});

test("native and agent edits serialize their whole read-modify-write interval", async () => {
  await files.write("artifacts/result.md", "first\nsecond");
  await Promise.all([files.edit("artifacts/result.md", [{ oldText: "first", newText: "FIRST" }]),
    files.edit("artifacts/result.md", [{ oldText: "second", newText: "SECOND" }])]);
  expect(await files.read("artifacts/result.md")).toBe("FIRST\nSECOND");
});

test("binary chunks are bounded and replacements reclaim only unreferenced blobs", async () => {
  const bytes = Uint8Array.from({ length: 400_000 }, (_, index) => index % 256);
  await files.write("artifacts/chart.png", bytes);
  expect(await files.read("artifacts/chart.png")).toEqual(bytes);
  expect((await db.get<{ maximum: number }>("SELECT MAX(length(bytes)) AS maximum FROM ox_blob_chunks"))!.maximum).toBeLessThanOrEqual(128 * 1024);
  await files.write("artifacts/chart.png", new Uint8Array([0, 255, 3]));
  await files.collectOrphanBlobs();
  expect(await db.all("SELECT id FROM ox_blobs")).toHaveLength(1);
  expect(await files.read("artifacts/chart.png")).toEqual(new Uint8Array([0, 255, 3]));
  await files.remove("artifacts/chart.png"); await files.collectOrphanBlobs();
  expect(await db.all("SELECT id FROM ox_blobs")).toHaveLength(0);
  expect(await db.all("SELECT id FROM ox_blob_chunks")).toHaveLength(0);
});

test("empty binary artifacts and missing references do not silently invent content", async () => {
  await files.write("artifacts/empty.bin", new Uint8Array());
  expect(await files.read("artifacts/empty.bin")).toEqual(new Uint8Array());
  await db.run("DELETE FROM ox_blobs");
  await expect(files.read("artifacts/empty.bin")).rejects.toThrow("reference");
});

test("invalid edits, limits and private paths preserve previous content", async () => {
  await files.write("SOUL.md", "same same\nend");
  await expect(files.edit("SOUL.md", [{ oldText: "same", newText: "lost" }])).rejects.toThrow("exactly once");
  await expect(files.edit("SOUL.md", [{ oldText: "same same", newText: "x" }, { oldText: "same\nend", newText: "y" }])).rejects.toThrow("overlap");
  await expect(files.write("SOUL.md", "x".repeat(200 * 1024 + 1))).rejects.toThrow("limit");
  expect(await files.read("SOUL.md")).toBe("same same\nend");
  for (const path of ["../MEMORY.md", "/../MEMORY.md", "artifacts/.saved.json", "skills/../../secret", "\\private", "a//b", "a\0b"]) {
    expect(() => canonical(path)).toThrow();
  }
  await expect(files.write("session.sqlite", "private")).rejects.toThrow("not writable");
  await expect(files.write("chats/id/turns.jsonl", "private")).rejects.toThrow("not writable");
});

test("fixture schema rejection preserves incompatible bytes instead of late missing-column failures", async () => {
  await db.exec("DROP TABLE ox_blob_chunks; DROP TABLE ox_blobs; CREATE TABLE ox_blobs (id TEXT PRIMARY KEY, old_size INTEGER NOT NULL) STRICT;");
  await expect(files.initialize()).rejects.toThrow("Unsupported blob fixture schema");
  expect((await db.all<{ name: string }>("PRAGMA table_info(ox_blobs)")).map(row => row.name)).toEqual(["id", "old_size"]);
  expect(await db.all("SELECT name FROM sqlite_master WHERE name='ox_blob_chunks'")).toHaveLength(0);
});

test("document checkpoint policy bounds replay and binary admission freezes caller-owned bytes", async () => {
  for (let i = 0; i < 70; i++) await files.write("MEMORY.md", `revision ${i}`);
  expect(await files.read("MEMORY.md")).toBe("revision 69");
  const tails = await db.all<{ deltas: number }>("SELECT sum(kind='delta') AS deltas FROM document_revisions GROUP BY document_id");
  expect(tails.every(row => row.deltas <= 31)).toBe(true);
  const bytes = new Uint8Array([0, 1, 255]);
  const pending = files.write("artifacts/frozen.bin", bytes); bytes.fill(42);
  await pending;
  expect(await files.read("artifacts/frozen.bin")).toEqual(new Uint8Array([0, 1, 255]));
});

test("file-backed host integrates actual Pi SQLite commits, physical files, history, corruption and reopen", async () => {
  const directory = await mkdtemp("/tmp/ox-artifacts-integration-");
  const hash = (bytes: Uint8Array) => new Bun.CryptoHasher("sha256").update(bytes).digest("hex");
  const host = (root = directory): ArtifactFiles => {
    let closed = false;
    const path = (name: string) => {
      if (closed) throw new Error("Native file owner closed");
      return `${root}/${artifactPath(name)}`;
    };
    return {
      async publish(name, bytes) {
        const file = await open(path(name), constants.O_CREAT | constants.O_EXCL | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
        try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
        return { path: name, size: bytes.length, sha256: hash(bytes) };
      },
      async read(record) {
        const file = await open(path(record.path), constants.O_RDONLY | constants.O_NOFOLLOW);
        try {
          const bytes = await file.readFile();
          if (bytes.length !== record.size || hash(bytes) !== record.sha256) throw new Error("Invalid native artifact digest");
          return bytes;
        } finally { await file.close(); }
      },
      async flush(name) { const file = await open(path(name), "r"); try { await file.sync(); } finally { await file.close(); } },
      async close() { closed = true; },
    };
  };
  const models = createModels();
  const provider = fauxProvider({ provider: "image-fixture", models: [{ id: "mock" }], tokensPerSecond: 100_000 });
  provider.setResponses([
    fauxAssistantMessage({ type: "toolCall", id: "read-image", name: "read", arguments: { path: "artifacts/chart.png" } }, { stopReason: "toolUse" }),
    transcript => {
      const image = transcript.messages.find(message => message.role === "toolResult");
      expect(image?.content as unknown).toEqual([{ type: "text", text: "[Attachment: artifacts/chart.png]", oxAttachment: "chart.png", oxProfileID: "physical-profile" }]);
      return fauxAssistantMessage("Image reference committed");
    },
  ]);
  models.setProvider(provider.provider);
  const openSession = () => openOxAgentSession({ database: backend(`${directory}/state.sqlite`).db, profileID: "physical-profile",
    models, registry: createRegistry(), artifacts: host(), authorizeFile: async () => {} });
  await mkdir(`${directory}/artifacts`);
  let session = await openSession();
  try {
    await session.files.write("artifacts/report.md", "你好 😀\noriginal");
    await session.files.write("artifacts/chart.bin", new Uint8Array([0, 255, 3]));
    await session.files.write("MEMORY.md", "document only");
    expect(await readFile(`${directory}/artifacts/report.md`, "utf8")).toBe("你好 😀\noriginal");
    await expect(readFile(`${directory}/MEMORY.md`)).rejects.toThrow();
    await expect(session.files.write("artifacts/report.md", "replace")).rejects.toThrow("immutable");
    await expect(session.files.edit("artifacts/report.md", [{ oldText: "original", newText: "changed" }])).rejects.toThrow("immutable");
    await session.files.remove("artifacts/report.md");
    await expect(session.files.read("artifacts/report.md")).rejects.toThrow("not found");
    expect(await session.files.readReference("artifacts/report.md")).toBe("你好 😀\noriginal");
    await expect(session.files.write("artifacts/report.md", "reuse")).rejects.toThrow("immutable");
    await session.close(); session = await openSession();
    expect(await session.files.readReference("artifacts/report.md")).toBe("你好 😀\noriginal");
    expect(await session.files.read("artifacts/chart.bin")).toEqual(new Uint8Array([0, 255, 3]));
    expect(await session.files.read("MEMORY.md")).toBe("document only");
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD3sAAAAASUVORK5CYII=";
    await session.files.write("artifacts/chart.png", Buffer.from(png, "base64"));
    const conversation = await session.harness.createConversation({ ownership: { kind: "ownerless" } }, BACKGROUND_CONTEXT);
    await conversation.configure({ model: { provider: "image-fixture", modelId: "mock" },
      extensions: [session.registry.snapshot().extension("ox-profile-files")!] }, BACKGROUND_CONTEXT);
    const result = await session.run(session.conversations.reference(conversation.id), { type: "input", content: "Read the owned image" });
    expect(result.receipt.status).toBe("done");
    const ledger = await conversation.entries({}, 100, undefined, BACKGROUND_CONTEXT);
    expect(JSON.stringify(ledger.items)).not.toContain(png);
    expect(JSON.stringify(ledger.items)).toContain("oxProfileID");
    const installed = `${directory}/installed`;
    await mkdir(`${installed}/artifacts`, { recursive: true });
    const imageBytes = Buffer.from(png, "base64");
    await writeFile(`${installed}/artifacts/chart.png`, imageBytes);
    const old = { role: "user" as const, content: "Full retained ledger", timestamp: 1 };
    const summary = { role: "user" as const, content: "Compacted context", timestamp: 2 };
    const tail = { role: "user" as const, content: [Object.assign({ type: "text" as const, text: "[Attachment: artifacts/chart.png]" },
      { oxAttachment: "chart.png", oxProfileID: "installed-profile" })], timestamp: 3 };
    const draft: NormalizedProfileDraft = { format: 1, profileID: "installed-profile",
      documents: [{ path: "MEMORY.md", text: "Installed memory" }],
      artifacts: [{ path: "artifacts/chart.png", size: imageBytes.length, sha256: hash(imageBytes), binary: true, saved: true }],
      conversations: [{ key: "source-key", title: "Preserved title", favorite: true, unread: false,
        agent: { model: { provider: "native-source", modelId: "model" }, thinkingLevel: "high" }, metadata: { createdAt: 42, scheduledSkillID: "schedule" },
        entries: [{ kind: "pi.user", model: [old], data: { retained: "application data" } },
          { kind: "pi.reset", head: "self", model: [summary] }, { kind: "pi.user", model: [tail] }], expectedContext: [summary, tail] }] };
    const installation = await installOxProfile(draft, { database: backend(`${installed}/state.sqlite`).db, artifacts: host(installed) });
    expect(installation.conversations).toHaveLength(1);
    expect(installation.conversations[0]!.key).toBe("source-key");
    const installedSession = await openOxAgentSession({ database: backend(`${installed}/state.sqlite`).db,
      profileID: draft.profileID, models: createModels(), artifacts: host(installed), authorizeFile: async () => {} });
    try {
      const reference = installation.conversations[0]!.reference;
      expect((await installedSession.conversations.history(reference)).items).toHaveLength(3);
      expect((await installedSession.inspect(reference)).messages).toEqual([summary, tail]);
      expect(await installedSession.files.readReference("artifacts/chart.png")).toEqual(imageBytes);
      expect((await installedSession.conversations.metadata(reference)).favorite).toBe(true);
      expect((await installedSession.inspect()).inspection.tasks).toHaveLength(0);
    } finally { await installedSession.close(); }
    const installedProbe = backend(`${installed}/state.sqlite`);
    expect(await installedProbe.db.all("SELECT name FROM sqlite_master WHERE name IN ('ox_chats','ox_blobs','ox_blob_chunks')")).toHaveLength(0);
    expect(await installedProbe.db.all("SELECT id FROM submissions")).toHaveLength(0);
    expect(await installedProbe.db.all("SELECT id FROM tasks")).toHaveLength(0);
    expect(await installedProbe.db.all("SELECT id FROM documents WHERE kind='\"ox.chat\"'")).toHaveLength(0);
    await installedProbe.db.close();
    await expect(installOxProfile(draft, { database: backend(`${installed}/state.sqlite`).db, artifacts: host(installed) })).rejects.toThrow("fresh staged database");
    const untouched = backend(`${installed}/state.sqlite`);
    expect(await untouched.db.all("SELECT id FROM entries")).toHaveLength(3);
    await untouched.db.close();
    const foreign = `${directory}/foreign`;
    await mkdir(foreign);
    await expect(installOxProfile({ ...draft, profileID: "another-profile" },
      { database: backend(`${foreign}/state.sqlite`).db, artifacts: host(foreign) })).rejects.toThrow("owning Profile");
    await writeFile(`${directory}/artifacts/chart.bin`, new Uint8Array([1, 1, 1]));
    await expect(session.files.read("artifacts/chart.bin")).rejects.toThrow("digest");
    await session.close();
    const probe = backend(`${directory}/state.sqlite`);
    expect(await probe.db.all("SELECT name FROM sqlite_master WHERE name IN ('ox_blobs','ox_blob_chunks')")).toHaveLength(0);
    await probe.db.close();
  } finally { await session.close(); await rm(directory, { recursive: true, force: true }); }
});

test("virtual environment has one Profile identity, line EOF semantics, and no shell", async () => {
  await files.write("MEMORY.md", "line one\nline two\n");
  const env = profileEnv(files);
  expect(env.id).toBe(profileEnv(files).id);
  expect((await env.exec("anything", undefined, BACKGROUND_CONTEXT)).ok).toBe(false);
  const shell = await env.exec("anything", undefined, BACKGROUND_CONTEXT);
  if (!shell.ok) expect(shell.error.code).toBe("shell_unavailable");
  expect(await env.canonicalPath("/MEMORY.md", BACKGROUND_CONTEXT)).toEqual({ ok: true, value: "/MEMORY.md" });
  const reader = await env.openTextLineReader("MEMORY.md", BACKGROUND_CONTEXT);
  if (!reader.ok) throw reader.error;
  expect(await reader.value.readLine(BACKGROUND_CONTEXT)).toEqual({ ok: true, value: { text: "line one", terminated: true } });
  expect(await reader.value.readLine(BACKGROUND_CONTEXT)).toEqual({ ok: true, value: { text: "line two", terminated: true } });
  expect(await reader.value.readLine(BACKGROUND_CONTEXT)).toEqual({ ok: true, value: undefined });
  await reader.value.close(BACKGROUND_CONTEXT);
  expect((await reader.value.readLine(BACKGROUND_CONTEXT)).ok).toBe(false);
});

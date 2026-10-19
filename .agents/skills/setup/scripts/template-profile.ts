import { Database } from "bun:sqlite";
import { mkdir, mkdtemp, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { nativeDatabase } from "../../../../packages/agent/src/sqlite.ts";
import { openProfileRuntime, type ProfileRuntimeOptions } from "../../../../packages/agent/src/profile/runtime.ts";
import { ApplicationPresentation } from "../../../../packages/agent/src/profile/presentation.ts";
import type { ProfileFileBackend, ProfileFileRecord, FileMutation, FileObservation } from "../../../../packages/agent/src/profile/file-store.ts";
import { relativeStoragePath, type PreparedTemplate } from "./template-schema.ts";

const digest = (bytes: Uint8Array) => new Bun.CryptoHasher("sha256").update(bytes).digest("hex");
type EntryDraft = NonNullable<Parameters<ApplicationPresentation["create"]>[0]["entries"]>[number];
const dormantModels = new Proxy({} as ProfileRuntimeOptions["models"], { get: (_, key) => () => { throw new Error(`Template materialization cannot invoke Models.${String(key)}`); } });

function database(path: string) {
  const connection = new Database(path);
  connection.exec("PRAGMA foreign_keys=ON");
  return nativeDatabase(async (op, sql, params) => {
    if (op === "close") { connection.close(); return null; }
    if (op === "exec") { connection.exec(sql); return null; }
    const bindings = params.map(value => {
      if (value && typeof value === "object" && "blob" in value) return new Uint8Array(value.blob as number[]);
      if (value && typeof value === "object" && "integer" in value) return BigInt(value.integer as string);
      return value;
    });
    const statement = connection.query(sql);
    if (op === "run") { statement.run(...bindings as never[]); return null; }
    return op === "get" ? statement.get(...bindings as never[]) : statement.all(...bindings as never[]);
  });
}

function stagedFiles(content: string, staging: string): ProfileFileBackend {
  const file = (path: string) => join(content, relativeStoragePath(path));
  const source = (path: string) => {
    if (!/^staging\/[A-F0-9-]+$/.test(path)) throw new Error("Invalid staged template file");
    return join(staging, path.slice(8));
  };
  const bytes = async (record: { path: string; size: number; sha256: string }) => {
    const data = new Uint8Array(await Bun.file(record.path.startsWith("staging/") ? source(record.path) : file(record.path)).arrayBuffer());
    if (data.length !== record.size || digest(data) !== record.sha256) throw new Error("Template file integrity mismatch");
    return data;
  };
  const inventory = async () => {
    const files: string[] = [], directories: string[] = [];
    const visit = async (path: string) => {
      for (const entry of await readdir(join(content, path), { withFileTypes: true })) {
        const child = path ? `${path}/${entry.name}` : entry.name;
        if (entry.isDirectory()) { directories.push(child); await visit(child); }
        else if (entry.isFile()) files.push(child);
        else throw new Error("Template files contain a non-regular entry");
      }
    };
    await visit("");
    return { files, directories };
  };
  const validate = async (operations: FileMutation[]) => {
    for (const operation of operations) {
      file(operation.path);
      if (operation.op === "replace") {
        await bytes({ path: operation.source, size: operation.size, sha256: operation.sha256 });
        if (operation.previous) await bytes({ path: operation.path, ...operation.previous });
        else if (await Bun.file(file(operation.path)).exists()) throw new Error("Template destination already exists");
      }
      if (operation.op === "move") await bytes({ path: operation.source, size: operation.size, sha256: operation.sha256 });
    }
  };
  return {
    async stage(data) {
      const path = `staging/${crypto.randomUUID().toUpperCase()}`;
      await writeFile(source(path), data, { flag: "wx", mode: 0o600 });
      return { path, size: data.length, sha256: digest(data) };
    },
    validate,
    async apply(operations) {
      await validate(operations);
      for (const operation of operations) {
        const destination = file(operation.path);
        if (operation.op === "mkdir") await mkdir(destination, { recursive: true });
        else if (operation.op === "replace") await rename(source(operation.source), destination);
        else if (operation.op === "move") await rename(file(operation.source), destination);
        else await rm(destination, { recursive: operation.directory });
      }
    },
    async snapshot(known: ProfileFileRecord[]) {
      const entries = await inventory();
      const files: FileObservation[] = [];
      for (const path of entries.files) {
        const data = new Uint8Array(await Bun.file(file(path)).arrayBuffer());
        const info = await stat(file(path));
        const previous = known.find(item => item.path === path);
        files.push({ path, size: data.length, sha256: digest(data), binary: previous?.binary ?? true, mtime: info.mtimeMs, stamp: `${info.ino}:${info.size}:${info.mtimeMs}` });
      }
      return { files, directories: entries.directories };
    },
    read: bytes,
    async readRange(record, offset, length) {
      if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || offset + length > record.size) throw new Error("Invalid template file range");
      return (await bytes(record)).slice(offset, offset + length).toBase64();
    },
    async identifier() { return crypto.randomUUID().toUpperCase(); },
    async inventory() { return (await inventory()).files; },
    async verify(record) { await bytes(record); },
    async sweep() { for (const name of await readdir(staging)) await rm(join(staging, name)); },
    async close() {},
  };
}

function decoded(data: string): string | Uint8Array {
  const bytes = Uint8Array.fromBase64(data);
  if (bytes.length <= 200 * 1024) {
    try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch {}
  }
  return bytes;
}

export async function materializeProfiles(template: PreparedTemplate, parent: string) {
  if (template.profiles?.some(profile => profile.conversations?.some(conversation => conversation.packageData))) throw new Error("Desktop conversation-package materialization is not yet supported");
  const schemaSource = await Bun.file(new URL("../../../../apps/shared/Host/Storage/ProfileMigrator.swift", import.meta.url)).text();
  const milestones = /enum ProfileSchema\s*\{\s*static let versions = \[([^\]]+)\]/.exec(schemaSource)?.[1];
  const version = milestones && [...milestones.matchAll(/"([^"]+)"/g)].at(-1)?.[1];
  if (!version) throw new Error("Cannot resolve the native current Profile schema");
  const root = await mkdtemp(join(parent, "profiles-"));
  const profiles: Record<string, { id: string; name: string; content: string; state: string; conversations: Record<string, number> }> = {};
  try {
    for (const input of template.profiles ?? []) {
      const id = crypto.randomUUID().toUpperCase();
      const name = `QA-${template.runID.slice(0, 8)}-${input.name}`;
      const content = join(root, "Documents/Profiles", name);
      const state = join(root, "Library/Application Support/Profiles", id);
      const staging = join(root, "staging", id);
      for (const path of [content, state, staging]) await mkdir(path, { recursive: true, mode: 0o700 });
      const backend = stagedFiles(content, staging);
      const runtime = await openProfileRuntime({ database: database(join(state, "state.sqlite")), profileID: id, models: dormantModels,
        fileStorage: { kind: "prepare", publicFiles: true, backend } });
      const conversations: Record<string, number> = {};
      try {
        await runtime.files.install([], []);
        await runtime.files.bindPhysicalFiles(true);
        if (input.memory !== undefined) await runtime.files.writeDocument("MEMORY.md", input.memory);
        if (input.soul !== undefined) await runtime.files.writeDocument("SOUL.md", input.soul);
        for (const item of input.files ?? []) await runtime.files.write(item.path, decoded(item.data));
        const presentation = new ApplicationPresentation(runtime);
        for (const conversation of input.conversations ?? []) {
          const created = await presentation.create({ title: conversation.title, favorite: conversation.favorite, unread: conversation.unread,
            agent: conversation.model && { model: { modelId: conversation.model.model },
              thinkingLevel: (["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const).find(level => level === conversation.model?.thinking) },
            metadata: { createdAt: Date.now() / 1000 - 978307200, attachedServiceDomains: [],
              nativeProviderID: conversation.model?.provider ?? null,
              nativeReasoningEffort: conversation.model?.thinking && !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(conversation.model.thinking) ? conversation.model.thinking : null } });
          conversations[conversation.id] = created.conversationID;
          const attachments = new Map<string, string>();
          for (const item of conversation.files ?? []) {
            const path = `conversations/${created.conversationID}/${item.name}`;
            await runtime.files.write(path, decoded(item.data));
            attachments.set(item.id, (await runtime.files.record(path, false))!.id);
          }
          const entries: EntryDraft[] = (conversation.messages ?? []).map((message, index): EntryDraft => {
            const content: Array<{ type: "text"; text: string; oxAttachment?: string; oxProfileID?: string }> = [{ type: "text", text: message.text }];
            if (message.role === "user") {
              for (const attachment of message.attachments ?? []) {
                const filename = attachments.get(attachment)!;
                content.push({ type: "text", text: `[Attachment: artifacts/${filename}]`, oxAttachment: filename, oxProfileID: id });
              }
              return { kind: "ox.native.turn", data: {}, model: [{ role: "user", content, timestamp: Date.now() + index }] };
            }
            return { kind: "ox.native.turn", data: {}, model: [{ role: "assistant", api: "ox-native", provider: conversation.model?.provider ?? "mock",
              model: conversation.model?.model ?? "mock", content: [...(message.reasoning ? [{ type: "thinking" as const, thinking: message.reasoning }] : []), ...content],
              usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
              stopReason: "stop", timestamp: Date.now() + index }] };
          });
          await presentation.populate(created.reference, entries);
          await presentation.save(created.reference, { favorite: conversation.favorite, unread: conversation.unread });
        }
        const inspection = await runtime.inspect();
        if (inspection.inspection.tasks.length || inspection.inspection.submissions.length || inspection.inspection.scheduling !== "paused") throw new Error("Template Profile must remain dormant");
      } finally { await runtime.close(); }
      await writeFile(join(state, "profile.json"), JSON.stringify({ id, createdAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), version, contentDirectory: name }, null, 2) + "\n", { flag: "wx", mode: 0o600 });
      profiles[input.id] = { id, name, content, state, conversations };
    }
    await rm(join(root, "staging"), { recursive: true, force: true });
    return { root, profiles };
  } catch (error) {
    await rm(root, { recursive: true, force: true });
    throw error;
  }
}

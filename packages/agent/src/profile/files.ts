import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, defineDocFamily, type Harness, type ConversationId, type EntryDraft } from "@earendil-works/pi-durable";
import { FileError } from "@earendil-works/pi-durable/env";
import type { SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { legacyFilePath, validateFileRecord, type FilePayloadStore } from "./file-payloads";
import { RESERVED_SKILL_NAMES } from "@openox/protocol/skills";
import { canonical } from "../core/file-paths";
import { publicDocument, ProfileFileStore, type ProfileFileBackend, type ProfileFileRecord } from "./file-store";
import type { FileRecord } from "./file-record";
export { canonical } from "../core/file-paths";

const context = BACKGROUND_CONTEXT;
const textLimit = 200 * 1024;
const binaryLimit = 32 * 1024 * 1024;
const chunkSize = 128 * 1024;
export const ProfileIndex = defineDoc<{ identity: string; files: Record<string, { size: number; mtime: number; binary: boolean }> }>({
  kind: "ox.profile", version: 1, scope: "session", initial: () => ({ identity: "", files: {} }),
  checkpointWhen: (_, __, info) => info.deltasSinceBase >= 31,
});
export const ProfileFile = defineDocFamily<{ text: string; blob: string; saved: boolean }, null>({
  kind: "ox.file", version: 1, scope: "session", family: true, initial: () => ({ text: "", blob: "", saved: false }),
  checkpointWhen: (_, __, info) => info.deltasSinceBase >= 31,
});
/** Immutable publication metadata remains addressable after logical removal. */
export const LegacyProfileFile = defineDocFamily<{ path: string; size: number; sha256: string; binary: boolean; saved: boolean }, null>({
  kind: "ox.artifact", version: 1, scope: "session", family: true,
  initial: () => ({ path: "", size: 0, sha256: "", binary: false, saved: false }),
  checkpointWhen: (_, __, info) => info.deltasSinceBase >= 31,
});

const FilesystemBinding = defineDoc<{ backend: string }>({
  kind: "ox.filesystem", version: 1, scope: "session", initial: () => ({ backend: "" }),
});

function owned(path: string) {
  if (path.startsWith("skills/") && (RESERVED_SKILL_NAMES as readonly string[]).includes(path.split("/")[1]!)) throw new FileError("permission_denied", "Bundled System skill names are reserved", path);
  if (!["MEMORY.md", "SOUL.md", "skill-selections.json"].includes(path) && !/^(artifacts|skills)\//.test(path)) {
    throw new FileError("permission_denied", "Path is not writable Profile content", path);
  }
  if (path.startsWith("artifacts/") && path.split("/").length !== 2) throw new FileError("invalid", "Legacy files have flat names", path);
}

/** One mutation owner. Native publications precede Pi references; historical files are retained.
 * SQL blobs remain only for explicitly selected legacy cache/integration fixtures.
 */
export class ProfileFiles {
  private tail: Promise<unknown> = Promise.resolve();
  get immutableFiles() { return this.filePayloads !== undefined; }
  private harness: Harness;
  private db: SqliteDatabase;
  readonly identity: string;
  private createBlobID?: () => Promise<string>;
  private filePayloads?: FilePayloadStore;
  private bindingMode: "legacy" | "physical" | "prepare";
  private store?: ProfileFileStore;
  private publicFiles = false;
  get physical() { return this.store !== undefined; }
  usePublicFiles() { this.publicFiles = true; }
  private physicalStore() {
    if (!this.store) throw new FileError("not_supported", "Physical Profile files are unavailable");
    return this.store;
  }
  state() { return this.physicalStore().state(); }
  record(path: string, reference = true) { return this.physicalStore().record(path, reference); }
  records(paths: string[]) { return this.physicalStore().records(paths); }
  discard(reference: string, conversation: number) { return this.physicalStore().discard(reference, conversation); }
  writeStaged(path: string, file: FileRecord) { return this.physicalStore().writeStaged(path, file); }
  listFiles(prefix = "") { return this.physicalStore().listFiles(prefix); }
  info(path: string) { return this.physicalStore().info(path); }
  list(path: string) { return this.physicalStore().list(path); }
  snapshot(signal?: AbortSignal, prefix = "") { return this.physicalStore().snapshot(signal, prefix); }
  readRange(path: string, offset: number, length: number) { return this.physicalStore().readRange(path, offset, length); }
  mkdir(path: string, recursive = false) { return this.physicalStore().mkdir(path, recursive); }
  move(from: string, to: string) { return this.physicalStore().move(from, to); }
  copy(from: string, to: string) { return this.physicalStore().copy(from, to); }
  saved(path: string, saved: boolean) { return this.physicalStore().saved(path, saved); }
  writeDocument(path: string, content: string) { return this.physicalStore().writeDocument(path, content); }
  seedDocument(path: string, content: string) { return this.physicalStore().seedDocument(path, content); }
  documentBatch(writes: { path: string; text: string }[], removes: string[]) { return this.physicalStore().documentBatch(writes, removes); }
  activatePublicFiles() { return this.physicalStore().activatePublicFiles(); }
  install(files: ProfileFileRecord[] = [], conversations: number[] = []) { return this.physicalStore().install(files, conversations); }
  installFileIndex(files: ProfileFileRecord[]) { return this.physicalStore().installFileIndex(files); }
  assignArchiveOwners(owners: Map<string, number>) { return this.physicalStore().assignArchiveOwners(owners); }
  publishConversation(id: ConversationId, entries: EntryDraft[], payloads: ProfileFileRecord[], newest: number | null) {
    return this.physicalStore().publishConversation(id, entries, payloads, newest);
  }
  async createConversation(id: ConversationId) { await this.store?.createConversation(id); }
  async deleteConversation(id: ConversationId) { await this.store?.deleteConversation(id); }

  constructor(harness: Harness, db: SqliteDatabase, identity: string,
    createBlobID?: () => Promise<string>, filePayloads?: FilePayloadStore, bindingMode: "legacy" | "physical" | "prepare" = "legacy",
    backend?: ProfileFileBackend, publicFiles = false) {
    this.harness = harness;
    this.db = db;
    this.identity = identity;
    this.createBlobID = createBlobID;
    this.filePayloads = filePayloads;
    this.bindingMode = bindingMode;
    if (bindingMode !== "legacy") {
      if (!backend) throw new Error("Physical filesystem backend is required");
      if (bindingMode === "physical" && filePayloads) throw new Error("Current filesystem cannot use the legacy file backend");
      this.store = new ProfileFileStore(harness, backend, publicFiles);
      this.publicFiles = publicFiles;
    }
  }
  private serialize<T>(body: () => Promise<T>): Promise<T> {
    const result = this.tail.then(body); this.tail = result.catch(() => {}); return result;
  }
  async initialize() {
    if (!this.identity) throw new Error("An immutable Profile identity is required");
    const existing = await this.harness.snapshot(ProfileIndex, context);
    if (existing?.identity && existing.identity !== this.identity) throw new Error("Profile identity does not match immutable runtime scope");
    const backend = this.bindingMode === "physical" ? this.publicFiles ? "public-profile-files-v1" : "profile-files-v1" : this.filePayloads ? "artifact-files-v1" : "fixture-blobs-v1";
    const binding = await this.harness.snapshot(FilesystemBinding, context);
    if (binding?.backend && binding.backend !== backend && !(this.bindingMode === "prepare" && ["workspace-files-v1", "profile-files-v1", "public-profile-files-v1"].includes(binding.backend))) throw new Error("Filesystem backend mismatch; explicit conversion is required");
    if (this.filePayloads || this.bindingMode !== "legacy") {
      if (await this.db.get("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('ox_blobs', 'ox_blob_chunks') LIMIT 1")) {
        throw new Error("Legacy blob fixture requires explicit conversion; open a fresh file-backed fixture");
      }
    } else {
      if (!this.createBlobID) throw new Error("Inject file payload storage, or explicitly select the legacy blob fixture");
      await this.validateBlobFixture();
      await this.db.exec("CREATE TABLE IF NOT EXISTS ox_blobs (id TEXT PRIMARY KEY, size INTEGER NOT NULL CHECK(size >= 0)) STRICT; CREATE TABLE IF NOT EXISTS ox_blob_chunks (id TEXT NOT NULL REFERENCES ox_blobs(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY (id, ordinal)) STRICT;");
    }
    await this.harness.commit(async tx => {
      const index = await tx.doc(ProfileIndex);
      if (index.identity && index.identity !== this.identity) throw new Error("Profile identity does not match immutable runtime scope");
      index.identity = this.identity;
      if (this.bindingMode !== "prepare" || !binding?.backend) (await tx.doc(FilesystemBinding)).backend = backend;
    }, context);
    if (this.bindingMode === "physical") await this.physicalStore().initialize();
  }
  async bindPhysicalFiles(publicFiles = false) {
    if (this.bindingMode !== "prepare") throw new Error("Profile file binding requires StorageMigrator preparation");
    await this.harness.commit(async tx => {
      const index = await tx.doc(ProfileIndex);
      for (const path of Object.keys(index.files)) if (path.startsWith("artifacts/")) delete index.files[path];
      if (publicFiles) for (const path of Object.keys(index.files)) if (publicDocument(path)) {
        delete index.files[path];
        await tx.retireDoc(ProfileFile, path);
      }
      (await tx.doc(FilesystemBinding)).backend = publicFiles ? "public-profile-files-v1" : "profile-files-v1";
    }, context);
  }
  private async validateBlobFixture() {
    const tables = await this.db.all<{ name: string; strict: number }>("PRAGMA table_list");
    const blob = tables.find(table => table.name === "ox_blobs");
    const chunks = tables.find(table => table.name === "ox_blob_chunks");
    if (!blob && !chunks) return;
    const columns = async (name: string) => (await this.db.all<{ name: string; type: string; pk: number; notnull: number }>(`PRAGMA table_info(${name})`))
      .map(column => `${column.name}:${column.type}:${column.pk}:${column.notnull}`).join(",");
    const foreign = await this.db.all<{ table: string; from: string; to: string; on_delete: string }>("PRAGMA foreign_key_list(ox_blob_chunks)");
    if (blob?.strict !== 1 || chunks?.strict !== 1 ||
      await columns("ox_blobs") !== "id:TEXT:1:1,size:INTEGER:0:1" ||
      await columns("ox_blob_chunks") !== "id:TEXT:1:1,ordinal:INTEGER:2:1,bytes:BLOB:0:1" ||
      foreign.length !== 1 || foreign[0].table !== "ox_blobs" || foreign[0].from !== "id" || foreign[0].to !== "id" || foreign[0].on_delete !== "CASCADE") {
      throw new Error("Unsupported blob fixture schema; open a fresh fixture rather than repairing legacy storage at runtime");
    }
  }
  async flush() { await this.tail; await this.store?.flush(); }
  async close() { await this.tail; await this.filePayloads?.close(); await this.store?.close(); }
  flushFile(path: string) {
    path = canonical(path);
    return this.serialize(async () => {
      if (this.store && (!this.isStoredDocument(path) || this.publicFiles && publicDocument(path))) { await this.store.flush(); return; }
      if (!(await this.index())[path]) throw new FileError("not_found", "File not found", path);
      if (this.filePayloads && path.startsWith("artifacts/")) await this.filePayloads.flush(legacyFilePath(path));
    });
  }
  /** Historical attachment access does not depend on membership in the visible file index. */
  readReference(path: string): Promise<string | Uint8Array> {
    return this.store ? this.store.read(path, true) : this.serialize(() => this.readStoredFile(legacyFilePath(path)));
  }
  private async readStoredFile(path: string): Promise<string | Uint8Array> {
    if (!this.filePayloads) throw new Error("File payload storage is not installed");
    const record = await this.harness.snapshot(LegacyProfileFile, path, context);
    if (!record || record.path !== path) throw new FileError("not_found", "File reference not found", path);
    validateFileRecord(record, path, record.size);
    if (record.size > (record.binary ? binaryLimit : textLimit)) throw new Error("File exceeds size limit");
    const bytes = await this.filePayloads.read(record);
    if (bytes.length !== record.size) throw new Error("File size does not match committed reference");
    return record.binary ? bytes : new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  }
  async integrity() { return (await this.db.get<{ integrity_check: string }>("PRAGMA integrity_check"))?.integrity_check; }
  async index() {
    const index = (await this.harness.snapshot(ProfileIndex, context))!.files;
    if (!this.publicFiles) return index;
    const documents = (await this.physicalStore().listFiles()).filter(file => !file.hidden && publicDocument(file.path));
    return { ...Object.fromEntries(Object.entries(index).filter(([path]) => !publicDocument(path))), ...Object.fromEntries(documents.map(file => [file.path, { size: file.size, mtime: file.mtime, binary: file.binary }])) };
  }
  private isStoredDocument(path: string) { return publicDocument(path) || path === "skill-selections.json"; }
  read(path: string): Promise<string | Uint8Array> {
    path = canonical(path);
    if (this.store && !this.isStoredDocument(path)) return this.store.read(path);
    return this.serialize(() => this.readLocked(path));
  }
  private async readLocked(path: string): Promise<string | Uint8Array> {
    path = canonical(path);
    if (this.publicFiles && publicDocument(path)) return this.physicalStore().read(path);
    const metadata = (await this.index())[path];
    if (!metadata) throw new FileError("not_found", "File not found", path);
    if (this.filePayloads && path.startsWith("artifacts/")) return this.readStoredFile(legacyFilePath(path));
    const file = await this.harness.snapshot(ProfileFile, path, context);
    if (!file) throw new Error("Missing Profile document");
    if (!metadata.binary) return file.text;
    if (metadata.size > binaryLimit) throw new Error("Binary file exceeds size limit");
    const record = await this.db.get<{ size: number }>("SELECT size FROM ox_blobs WHERE id = ?", file.blob);
    if (record?.size !== metadata.size) throw new Error("Invalid binary file size/reference");
    const content = new Uint8Array(metadata.size);
    // Bounded bridge chunks: do not turn a 32 MB blob into one enormous JSON number array.
    let offset = 0;
    for (let ordinal = 0; offset < content.length; ordinal++) {
      const row = await this.db.get<{ bytes: Uint8Array }>("SELECT bytes FROM ox_blob_chunks WHERE id = ? AND ordinal = ?", file.blob, ordinal);
      if (!row || row.bytes.length === 0 || offset + row.bytes.length > content.length) throw new Error("Invalid binary file reference");
      content.set(row.bytes, offset); offset += row.bytes.length;
    }
    return content;
  }
  async write(path: string, content: string | Uint8Array, expected?: string) {
    path = canonical(path);
    if (this.store && !this.isStoredDocument(path)) return this.store.write(path, content, expected);
    owned(path);
    const size = typeof content === "string" ? new TextEncoder().encode(content).length : content.length;
    if (size > (typeof content === "string" ? path === "MEMORY.md" ? 512 * 1024 : textLimit : binaryLimit)) throw new FileError("invalid", "File exceeds size limit", path);
    if (content instanceof Uint8Array) content = content.slice();
    if (this.publicFiles && publicDocument(path)) {
      if (typeof content !== "string") throw new FileError("invalid", "Profile documents require UTF-8 text", path);
      await this.physicalStore().writeDocument(path, content, expected); return;
    }
    await this.serialize(async () => {
      if (!(await this.index())[path] && Object.keys(await this.index()).length >= 10_000) throw new Error("Profile file count limit reached");
      if (this.filePayloads && path.startsWith("artifacts/")) {
        if (await this.harness.snapshot(LegacyProfileFile, path, context)) {
          throw new FileError("invalid", "Legacy file references are immutable; choose a distinct filename", path);
        }
        const bytes = typeof content === "string" ? new TextEncoder().encode(content) : content;
        const receipt = validateFileRecord(await this.filePayloads.publish(legacyFilePath(path), bytes), path, size);
        await this.harness.commit(async tx => {
          Object.assign(await tx.doc(LegacyProfileFile, path, null), receipt, { binary: typeof content !== "string" });
          (await tx.doc(ProfileIndex)).files[path] = { size, mtime: Date.now(), binary: typeof content !== "string" };
        }, context);
        return;
      }
      if (this.filePayloads && typeof content !== "string") throw new FileError("invalid", "Profile documents require UTF-8 text", path);
      let blob = "";
      if (typeof content !== "string") {
        blob = await this.createBlobID!();
        await this.db.transaction(async tx => {
          await tx.run("INSERT INTO ox_blobs VALUES (?, ?)", blob, size);
          for (let offset = 0; offset < size; offset += chunkSize) {
            await tx.run("INSERT INTO ox_blob_chunks VALUES (?, ?, ?)", blob, offset / chunkSize, content.subarray(offset, offset + chunkSize));
          }
        });
      }
      await this.harness.commit(async tx => {
        const index = await tx.doc(ProfileIndex);
        if (!index.files[path] && Object.keys(index.files).length >= 10_000) throw new Error("Profile file count limit reached");
        const file = await tx.doc(ProfileFile, path, null);
        file.text = typeof content === "string" ? content : ""; file.blob = blob;
        index.files[path] = { size, mtime: Date.now(), binary: typeof content !== "string" };
      }, context);
    });
  }
  async edit(path: string, edits: { oldText: string; newText: string }[]) {
    path = canonical(path);
    if (this.store && !this.isStoredDocument(path)) { await this.store.edit(path, edits); return; }
    owned(path);
    if (this.publicFiles && publicDocument(path)) { await this.physicalStore().edit(path, edits, true); return; }
    if (this.filePayloads && path.startsWith("artifacts/")) {
      throw new FileError("not_supported", "Legacy file references are immutable; write the edited content to a distinct filename", path);
    }
    await this.serialize(async () => {
      const original = await this.readLocked(path);
      if (typeof original !== "string") throw new FileError("invalid", "Only text can be edited", path);
      const ranges = edits.map(edit => {
        const start = original.indexOf(edit.oldText);
        if (!edit.oldText || start < 0 || original.indexOf(edit.oldText, start + 1) >= 0) throw new Error("Edit must match exactly once");
        return { ...edit, start, end: start + edit.oldText.length };
      }).sort((a, b) => a.start - b.start);
      if (ranges.some((range, index) => index > 0 && ranges[index - 1].end > range.start)) throw new Error("Edits overlap");
      let result = original;
      for (const range of [...ranges].reverse()) result = result.slice(0, range.start) + range.newText + result.slice(range.end);
      const size = new TextEncoder().encode(result).length;
      if (size > (path === "MEMORY.md" ? 512 * 1024 : textLimit)) throw new Error("Edited file exceeds size limit");
      await this.harness.commit(async tx => {
        (await tx.doc(ProfileFile, path, null)).text = result;
        (await tx.doc(ProfileIndex)).files[path] = { size, mtime: Date.now(), binary: false };
      }, context);
    });
  }
  async remove(path: string, directory = false, recursive = false) {
    path = canonical(path);
    if (["MEMORY.md", "skill-selections.json"].includes(path)) throw new FileError("permission_denied", "Profile documents cannot be removed", path);
    if (this.store && (this.publicFiles || !this.isStoredDocument(path))) { await this.store.remove(path, directory, recursive); return; }
    owned(path);
    await this.serialize(() => this.harness.commit(async tx => {
      delete (await tx.doc(ProfileIndex)).files[path];
      if (!this.filePayloads || !path.startsWith("artifacts/")) await tx.retireDoc(ProfileFile, path);
    }, context));
  }
  async collectOrphanBlobs() {
    if (this.filePayloads) throw new Error("File reclamation requires a complete history/export reference set; automatic deletion is disabled");
    return this.serialize(async () => {
      const referenced = new Set<string>();
      for (const path of Object.keys(await this.index())) {
        const file = await this.harness.snapshot(ProfileFile, path, context);
        if (file?.blob) referenced.add(file.blob);
      }
      await this.db.transaction(async tx => {
        for (const row of await tx.all<{ id: string }>("SELECT id FROM ox_blobs")) {
          if (!referenced.has(row.id)) await tx.run("DELETE FROM ox_blobs WHERE id = ?", row.id);
        }
      });
    });
  }
}

import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, defineDocFamily, type Harness } from "@earendil-works/pi-durable";
import { FileError } from "@earendil-works/pi-durable/env";
import type { SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { artifactPath, artifactRecord, type ArtifactFiles } from "./artifacts";
import { SYSTEM_SKILL_NAMES } from "@openox/protocol/skills";
import { canonical } from "../core/file-paths";
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
export const ProfileArtifact = defineDocFamily<{ path: string; size: number; sha256: string; binary: boolean; saved: boolean }, null>({
  kind: "ox.artifact", version: 1, scope: "session", family: true,
  initial: () => ({ path: "", size: 0, sha256: "", binary: false, saved: false }),
  checkpointWhen: (_, __, info) => info.deltasSinceBase >= 31,
});

const FilesystemBinding = defineDoc<{ backend: string }>({
  kind: "ox.filesystem", version: 1, scope: "session", initial: () => ({ backend: "" }),
});

function owned(path: string) {
  if (path.startsWith("skills/") && (SYSTEM_SKILL_NAMES as readonly string[]).includes(path.split("/")[1]!)) throw new FileError("permission_denied", "Bundled System skill names are reserved", path);
  if (!["MEMORY.md", "SOUL.md", "skill-selections.json"].includes(path) && !/^(artifacts|skills)\//.test(path)) {
    throw new FileError("permission_denied", "Path is not writable Profile content", path);
  }
  if (path.startsWith("artifacts/") && path.split("/").length !== 2) throw new FileError("invalid", "Artifacts have flat names", path);
}

/** One mutation owner. Native publications precede Pi references; historical files are retained.
 * SQL blobs remain only for explicitly selected legacy cache/integration fixtures.
 */
export class ProfileFiles {
  private tail: Promise<unknown> = Promise.resolve();
  get immutableArtifacts() { return this.artifacts !== undefined; }
  constructor(private harness: Harness, private db: SqliteDatabase, readonly identity: string,
    private createBlobID?: () => Promise<string>, private artifacts?: ArtifactFiles) {}
  private serialize<T>(body: () => Promise<T>): Promise<T> {
    const result = this.tail.then(body); this.tail = result.catch(() => {}); return result;
  }
  async initialize() {
    if (!this.identity) throw new Error("An immutable Profile identity is required");
    const existing = await this.harness.snapshot(ProfileIndex, context);
    if (existing?.identity && existing.identity !== this.identity) throw new Error("Profile identity does not match immutable runtime scope");
    const backend = this.artifacts ? "artifact-files-v1" : "fixture-blobs-v1";
    const binding = await this.harness.snapshot(FilesystemBinding, context);
    if (binding?.backend && binding.backend !== backend) throw new Error("Filesystem backend mismatch; explicit conversion is required");
    if (this.artifacts) {
      if (await this.db.get("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('ox_blobs', 'ox_blob_chunks') LIMIT 1")) {
        throw new Error("Legacy blob fixture requires explicit conversion; open a fresh file-backed fixture");
      }
    } else {
      if (!this.createBlobID) throw new Error("Inject artifact files, or explicitly select the legacy blob fixture");
      await this.validateBlobFixture();
      await this.db.exec("CREATE TABLE IF NOT EXISTS ox_blobs (id TEXT PRIMARY KEY, size INTEGER NOT NULL CHECK(size >= 0)) STRICT; CREATE TABLE IF NOT EXISTS ox_blob_chunks (id TEXT NOT NULL REFERENCES ox_blobs(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY (id, ordinal)) STRICT;");
    }
    await this.harness.commit(async tx => {
      const index = await tx.doc(ProfileIndex);
      if (index.identity && index.identity !== this.identity) throw new Error("Profile identity does not match immutable runtime scope");
      index.identity = this.identity;
      (await tx.doc(FilesystemBinding)).backend = backend;
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
  async flush() { await this.tail; }
  async close() { await this.flush(); await this.artifacts?.close(); }
  flushFile(path: string) {
    path = canonical(path);
    return this.serialize(async () => {
      if (!(await this.index())[path]) throw new FileError("not_found", "File not found", path);
      if (this.artifacts && path.startsWith("artifacts/")) await this.artifacts.flush(artifactPath(path));
    });
  }
  /** Historical attachment access does not depend on membership in the visible file index. */
  readReference(path: string): Promise<string | Uint8Array> {
    return this.serialize(() => this.readArtifact(artifactPath(path)));
  }
  private async readArtifact(path: string): Promise<string | Uint8Array> {
    if (!this.artifacts) throw new Error("File-backed artifacts are not installed");
    const record = await this.harness.snapshot(ProfileArtifact, path, context);
    if (!record || record.path !== path) throw new FileError("not_found", "Artifact reference not found", path);
    artifactRecord(record, path, record.size);
    if (record.size > (record.binary ? binaryLimit : textLimit)) throw new Error("Artifact exceeds size limit");
    const bytes = await this.artifacts.read(record);
    if (bytes.length !== record.size) throw new Error("Artifact size does not match committed reference");
    return record.binary ? bytes : new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  }
  async integrity() { return (await this.db.get<{ integrity_check: string }>("PRAGMA integrity_check"))?.integrity_check; }
  async index() { return (await this.harness.snapshot(ProfileIndex, context))!.files; }
  read(path: string): Promise<string | Uint8Array> { return this.serialize(() => this.readLocked(path)); }
  private async readLocked(path: string): Promise<string | Uint8Array> {
    path = canonical(path);
    const metadata = (await this.index())[path];
    if (!metadata) throw new FileError("not_found", "File not found", path);
    if (this.artifacts && path.startsWith("artifacts/")) return this.readArtifact(artifactPath(path));
    const file = await this.harness.snapshot(ProfileFile, path, context);
    if (!file) throw new Error("Missing Profile document");
    if (!metadata.binary) return file.text;
    if (metadata.size > binaryLimit) throw new Error("Binary artifact exceeds size limit");
    const record = await this.db.get<{ size: number }>("SELECT size FROM ox_blobs WHERE id = ?", file.blob);
    if (record?.size !== metadata.size) throw new Error("Invalid binary artifact size/reference");
    const content = new Uint8Array(metadata.size);
    // Bounded bridge chunks: do not turn a 32 MB blob into one enormous JSON number array.
    let offset = 0;
    for (let ordinal = 0; offset < content.length; ordinal++) {
      const row = await this.db.get<{ bytes: Uint8Array }>("SELECT bytes FROM ox_blob_chunks WHERE id = ? AND ordinal = ?", file.blob, ordinal);
      if (!row || row.bytes.length === 0 || offset + row.bytes.length > content.length) throw new Error("Invalid binary artifact reference");
      content.set(row.bytes, offset); offset += row.bytes.length;
    }
    return content;
  }
  async write(path: string, content: string | Uint8Array) {
    path = canonical(path); owned(path);
    const size = typeof content === "string" ? new TextEncoder().encode(content).length : content.length;
    if (size > (typeof content === "string" ? textLimit : binaryLimit)) throw new FileError("invalid", "File exceeds size limit", path);
    if (content instanceof Uint8Array) content = content.slice(); // Freeze admission before waiting for the mutation queue.
    await this.serialize(async () => {
      if (!(await this.index())[path] && Object.keys(await this.index()).length >= 10_000) throw new Error("Profile file count limit reached");
      if (this.artifacts && path.startsWith("artifacts/")) {
        if (await this.harness.snapshot(ProfileArtifact, path, context)) {
          throw new FileError("invalid", "Artifact references are immutable; choose a distinct filename", path);
        }
        const bytes = typeof content === "string" ? new TextEncoder().encode(content) : content;
        const receipt = artifactRecord(await this.artifacts.publish(artifactPath(path), bytes), path, size);
        await this.harness.commit(async tx => {
          Object.assign(await tx.doc(ProfileArtifact, path, null), receipt, { binary: typeof content !== "string" });
          (await tx.doc(ProfileIndex)).files[path] = { size, mtime: Date.now(), binary: typeof content !== "string" };
        }, context);
        return;
      }
      if (this.artifacts && typeof content !== "string") throw new FileError("invalid", "Profile documents require UTF-8 text", path);
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
    path = canonical(path); owned(path);
    if (this.artifacts && path.startsWith("artifacts/")) {
      throw new FileError("not_supported", "Artifact references are immutable; write the edited content to a distinct filename", path);
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
      if (size > textLimit) throw new Error("Edited file exceeds size limit");
      await this.harness.commit(async tx => {
        (await tx.doc(ProfileFile, path, null)).text = result;
        (await tx.doc(ProfileIndex)).files[path] = { size, mtime: Date.now(), binary: false };
      }, context);
    });
  }
  async remove(path: string) {
    path = canonical(path); owned(path);
    await this.serialize(() => this.harness.commit(async tx => {
      delete (await tx.doc(ProfileIndex)).files[path];
      if (!this.artifacts || !path.startsWith("artifacts/")) await tx.retireDoc(ProfileFile, path);
      // Retain physical bytes and ox.artifact metadata for historical references.
    }, context));
  }
  async collectOrphanBlobs() {
    if (this.artifacts) throw new Error("Artifact reclamation requires a complete history/export reference set; automatic deletion is disabled");
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

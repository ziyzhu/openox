import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, type Harness, type ConversationId } from "@earendil-works/pi-durable";
import { FileError, type FileInfo } from "@earendil-works/pi-durable/env";
import { canonical } from "../core/file-paths";
import type { FileRecord } from "./file-record";
import { SYSTEM_SKILL_NAMES } from "@openox/protocol/skills";

export type WorkspaceMutation =
  | { op: "mkdir"; path: string }
  | { op: "replace"; path: string; source: string; size: number; sha256: string; previous: { size: number; sha256: string } | null }
  | { op: "move"; path: string; source: string; size: number; sha256: string }
  | { op: "remove"; path: string; directory: boolean };
export interface WorkspaceBackend {
  stage(bytes: Uint8Array): Promise<FileRecord>;
  apply(operations: WorkspaceMutation[]): Promise<void | { conflict: boolean }>;
  snapshot(files: WorkspaceFile[]): Promise<{ files: WorkspaceObservation[]; directories: string[] }>;
  validate(operations: WorkspaceMutation[]): Promise<void>;
  read(record: FileRecord): Promise<Uint8Array>;
  readRange(record: FileRecord, offset: number, length: number): Promise<string>;
  close(): Promise<void>;
  identifier(): Promise<string>;
  inventory(): Promise<string[]>;
  verify(record: FileRecord): Promise<void>;
  sweep(): Promise<void>;
}
export type WorkspaceFile = {
  path: string;
  size: number;
  sha256: string;
  id: string;
  aliases?: string[];
  binary: boolean;
  saved: boolean;
  mtime: number;
  owner: number | null;
  hidden?: boolean;
  stamp?: string;
}
export type WorkspaceObservation = FileRecord & { binary: boolean; mtime: number; stamp: string };
export const WorkspaceState = defineDoc<{
  initialized: boolean;
  files: Record<string, WorkspaceFile>;
  directories: string[];
  deletedConversations: number[];
  pending: WorkspaceMutation[];
  pendingIndex?: { files: Record<string, WorkspaceFile | null>; directories: string[] } | null;
}>({
  kind: "ox.workspace", version: 1, scope: "session",
  initial: () => ({ initialized: false, files: {}, directories: [], deletedConversations: [], pending: [], pendingIndex: null }),
  checkpointWhen: (_, __, info) => info.deltasSinceBase >= 31,
});
const context = BACKGROUND_CONTEXT;
const reserved = new Set(["payloads", "staging", "profile.json", "state.sqlite", "state.sqlite-wal", "state.sqlite-shm", "memory.md", "soul.md", "skill-selections.json", "skills", "services", "files", "history", "chats"]);
export const publicDocument = (path: string) => ["MEMORY.md", "SOUL.md"].includes(path) || path.startsWith("skills/");
export function documentPath(input: string) {
  const path = canonical(input);
  if (!publicDocument(path) || (path.startsWith("skills/") && (SYSTEM_SKILL_NAMES as readonly string[]).includes(path.split("/")[1]!))) {
    throw new FileError("permission_denied", "Expected a writable Profile document", input);
  }
  if (path.split("/").some(part => new TextEncoder().encode(part).length > 240) || new TextEncoder().encode(path).length > 4096 || path.split("/").length > 64) throw new FileError("invalid", "Profile document path exceeds limits", input);
  return path;
}
export function workspacePath(input: string) {
  const path = canonical(input);
  const parts = path.split("/");
  if (!path || reserved.has(parts[0]!.toLowerCase()) || parts[0]!.toLowerCase().startsWith("state.sqlite-") || parts.some(part => new TextEncoder().encode(part).length > 240 || /[\x00-\x1f\x7f]/u.test(part)) || new TextEncoder().encode(path).length > 4096 || parts.length > 64) {
    throw new FileError("permission_denied", "Path is not writable workspace content", input);
  }
  if (parts[0] === "conversations" && (parts.length < 2 || !/^(0|[1-9][0-9]*)$/.test(parts[1]!) || !Number.isSafeInteger(Number(parts[1])))) {
    throw new FileError("invalid", "Expected a canonical conversation directory", input);
  }
  return path;
}
const parent = (path: string) => path.split("/").slice(0, -1).join("/");
const beneath = (path: string, root: string) => path === root || path.startsWith(root + "/");
const owner = (path: string) => path.startsWith("conversations/") ? Number(path.split("/")[1]) : null;
const managed = (path: string) => path === "conversations" || /^conversations\/[0-9]+$/.test(path);

export class ProfileWorkspace {
  private tail: Promise<unknown> = Promise.resolve();
  private harness: Harness;
  private backend: WorkspaceBackend;
  private external: boolean;
  constructor(harness: Harness, backend: WorkspaceBackend, external = false) { this.harness = harness; this.backend = backend; this.external = external; }
  private serialize<T>(body: () => Promise<T>) {
    const next = this.tail.then(async () => { await this.recover(); if (this.external) await this.reconcile(); return body(); });
    this.tail = next.catch(() => {});
    return next;
  }
  async state() { return (await this.harness.snapshot(WorkspaceState, context)) ?? { initialized: false, files: {}, directories: [], deletedConversations: [], pending: [], pendingIndex: null }; }
  private async recover() {
    const state = await this.state();
    if (!state.pending.length) return true;
    const result = await this.backend.apply(state.pending);
    if (result?.conflict) {
      if (!this.external) throw new FileError("invalid", "Workspace recovery requires storage preparation");
      await this.reconcile(true);
      return false;
    }
    await this.harness.commit(async tx => {
      const current = await tx.doc(WorkspaceState);
      if (current.pendingIndex) {
        for (const [id, file] of Object.entries(current.pendingIndex.files)) {
          if (file) current.files[id] = file; else delete current.files[id];
        }
        current.directories = current.pendingIndex.directories;
      }
      current.pending = []; current.pendingIndex = null;
    }, context);
    return true;
  }
  private async identifier(path: string) {
    const suffix = path.split("/").at(-1)!.split(".").slice(1).at(-1) ?? "";
    const extension = new TextEncoder().encode(suffix).length <= 32 ? suffix : "";
    return `file-${await this.backend.identifier()}${extension ? "." + extension : ""}`;
  }
  private async reconcile(clearPending = false) {
    const state = await this.state();
    if (!state.initialized) return;
    const snapshot = await this.backend.snapshot(Object.values(state.files).filter(file => !file.hidden));
    const active = (path: string) => !state.deletedConversations.some(id => beneath(path, `conversations/${id}`));
    const accepted = (path: string) => {
      try { publicDocument(path) ? documentPath(path) : workspacePath(path); return active(path); }
      catch { return false; }
    };
    const files = Object.fromEntries(Object.entries(state.files).filter(([, file]) => file.hidden));
    const previous = new Map(Object.values(state.files).filter(file => !file.hidden).map(file => [file.path, file]));
    for (const observed of snapshot.files.filter(file => accepted(file.path))) {
      if (Object.values(files).some(file => file.path === observed.path)) continue;
      const existing = previous.get(observed.path);
      const id = existing?.id ?? await this.identifier(observed.path);
      files[id] = { ...observed, id, aliases: existing?.aliases ?? [], saved: existing?.saved ?? false, owner: owner(observed.path) };
    }
    const directories = snapshot.directories.filter(path => active(path) && (path === "conversations" || path === "skills" || accepted(path))).sort();
    const comparable = (value: unknown) => JSON.stringify(value, (_, item) => item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(Object.entries(item).sort(([a], [b]) => a.localeCompare(b))) : item);
    const changed = clearPending || comparable(files) !== comparable(state.files) || JSON.stringify(directories) !== JSON.stringify(state.directories);
    if (changed) await this.harness.commit(async tx => {
      const current = await tx.doc(WorkspaceState);
      current.files = files; current.directories = directories;
      if (clearPending) { current.pending = []; current.pendingIndex = null; }
    }, context);
  }
  async activatePublicFiles() {
    await this.flush(); this.external = true;
    await this.serialize(async () => {});
  }
  async flush() { await this.tail; await this.recover(); }
  async initialize() {
    await this.flush();
    const state = await this.state();
    for (const id of state.deletedConversations) {
      await (await this.harness.conversation(id as ConversationId, context))?.abort(context);
      if (state.directories.includes(`conversations/${id}`) || Object.values(state.files).some(file => file.owner === id)) await this.deleteConversation(id as ConversationId);
    }
    if (!(await this.state()).initialized) throw new Error("Workspace requires StorageMigrator preparation");
    await this.backend.sweep();
  }
  async install(files: WorkspaceFile[] = [], conversations: number[] = []) {
    await this.serialize(async () => {
      if ((await this.state()).initialized) return;
      for (const file of files) await this.backend.verify(file);
      const directories = new Set(["conversations", ...conversations.map(id => `conversations/${id}`)]);
      for (const file of files) {
        workspacePath(file.path);
        for (let path = parent(file.path); path; path = parent(path)) directories.add(path);
      }
      await this.harness.commit(async tx => {
        const state = await tx.doc(WorkspaceState);
        state.files = Object.fromEntries(files.map(file => [file.id, file]));
        state.directories = [...directories];
        state.pending = [...directories].sort((a, b) => a.length - b.length).map(path => ({ op: "mkdir", path }));
        state.initialized = true;
      }, context);
      await this.recover();
    });
  }
  private async commit(files: Record<string, WorkspaceFile>, directories: string[], operations: WorkspaceMutation[]) {
    if (Object.keys(files).length + directories.length > 10_000) throw new FileError("invalid", "Workspace entry limit reached");
    const previous = await this.state();
    const changes = Object.fromEntries([...new Set([...Object.keys(previous.files), ...Object.keys(files)])]
      .filter(id => JSON.stringify(previous.files[id]) !== JSON.stringify(files[id])).map(id => [id, files[id] ?? null]));
    await this.backend.validate(operations);
    await this.harness.commit(async tx => {
      const state = await tx.doc(WorkspaceState);
      if (operations.length) state.pendingIndex = { files: changes, directories };
      else { state.files = files; state.directories = directories; state.pendingIndex = null; }
      state.pending = operations;
    }, context);
    if (!(await this.recover())) throw new FileError("invalid", "External changes interrupted the operation; inspect current files before continuing");
  }
  private resolve(state: Awaited<ReturnType<ProfileWorkspace["state"]>>, input: string, reference = true) {
    const path = canonical(input), files = Object.values(state.files);
    return reference ? files.find(file => file.id === path || file.aliases?.includes(path)) : files.find(file => file.path === path);
  }
  record(input: string, reference = true) { return this.serialize(async () => this.resolve(await this.state(), input, reference)); }
  listFiles() { return this.serialize(async () => Object.values((await this.state()).files)); }
  private assertActive(state: Awaited<ReturnType<ProfileWorkspace["state"]>>, path: string) {
    const id = owner(path);
    if (id !== null && (!state.directories.includes(`conversations/${id}`) || state.deletedConversations.includes(id))) throw new FileError("not_found", "Conversation workspace unavailable", path);
  }
  private findPath(state: Awaited<ReturnType<ProfileWorkspace["state"]>>, path: string) {
    return Object.values(state.files).find(file => file.path.toLowerCase() === path.toLowerCase())?.path
      ?? state.directories.find(directory => directory.toLowerCase() === path.toLowerCase());
  }
  private parents(state: Awaited<ReturnType<ProfileWorkspace["state"]>>, path: string, recursive: boolean) {
    const missing: string[] = [];
    for (let current = parent(path); current; current = parent(current)) {
      const existing = this.findPath(state, current);
      if (existing && (!state.directories.includes(existing) || existing !== current)) throw new FileError("not_directory", "Parent is not an exact directory path", current);
      if (existing) break;
      if (!recursive) throw new FileError("not_found", "Parent directory not found", current);
      missing.unshift(current);
    }
    return missing;
  }
  info(input: string): Promise<FileInfo> {
    return this.serialize(async () => {
      const path = canonical(input), state = await this.state();
      const file = Object.values(state.files).find(file => !file.hidden && file.path === path);
      if (!path || state.directories.includes(path)) return { path: "/" + path, name: path.split("/").at(-1) ?? "", kind: "directory", size: 0, mtimeMs: 0 };
      if (file) return { path: "/" + path, name: path.split("/").at(-1)!, kind: "file", size: file.size, mtimeMs: file.mtime };
      throw new FileError("not_found", "File not found", input);
    });
  }
  async list(input: string) {
    if ((await this.info(input)).kind !== "directory") throw new FileError("not_directory", "Not a directory", input);
    const path = canonical(input), prefix = path ? path + "/" : "";
    const state = await this.state();
    const children = [...state.directories, ...Object.values(state.files).filter(file => !file.hidden).map(file => file.path)].filter(child => child.startsWith(prefix) && child !== path && !child.slice(prefix.length).includes("/"));
    return Promise.all(children.sort().map(child => this.info(child)));
  }
  read(input: string, reference = false): Promise<string | Uint8Array> {
    return this.serialize(async () => {
      const file = this.resolve(await this.state(), input, reference);
      if (!file || (!reference && file.hidden)) throw new FileError("not_found", "File unavailable", input);
      this.assertActive(await this.state(), file.path);
      const bytes = await this.backend.read(file);
      return file.binary ? bytes : new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    });
  }
  readRange(input: string, offset: number, length: number) {
    return this.serialize(async () => {
      const state = await this.state(), file = this.resolve(state, input);
      if (!file || (file.owner !== null && state.deletedConversations.includes(file.owner))) throw new FileError("not_found", "File unavailable", input);
      if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || length > 32 * 1024 * 1024 || offset > file.size || length > file.size - offset) throw new FileError("invalid", "Invalid bounded file range", input);
      return this.backend.readRange(file, offset, length);
    });
  }
  private async writeLocked(path: string, content: string | Uint8Array, expected?: string) {
    const state = await this.state();
    this.assertActive(state, path);
    const existingPath = this.findPath(state, path);
    if (existingPath && (existingPath !== path || state.directories.includes(path))) throw new FileError("invalid", "Destination collides with an existing entry", path);
    const existing = Object.values(state.files).find(file => file.path === path);
    if (existing?.hidden) throw new FileError("permission_denied", "Private blobs are not editable", path);
    if (expected !== undefined && existing?.binary) throw new FileError("not_supported", "Exact edits require a text file", path);
    if (expected !== undefined && (!existing || new TextDecoder("utf-8", { fatal: true }).decode(await this.backend.read(existing)) !== expected)) throw new FileError("invalid", "File changed after reading; read again before editing", path);
    const bytes = typeof content === "string" ? new TextEncoder().encode(content) : content;
    if (bytes.length > (typeof content === "string" ? 200 * 1024 : 32 * 1024 * 1024)) throw new FileError("invalid", "File exceeds size limit", path);
    const directories = this.parents(state, path, true);
    if (Object.keys(state.files).length + state.directories.length + directories.length + (existing ? 0 : 1) > 10_000) throw new FileError("invalid", "Workspace entry limit reached");
    const id = existing?.id ?? await this.identifier(path);
    const staged = await this.backend.stage(bytes);
    const file: WorkspaceFile = { ...staged, id, path, aliases: existing?.aliases ?? [], binary: typeof content !== "string", saved: existing?.saved ?? false, mtime: Date.now(), owner: owner(path) };
    await this.commit({ ...state.files, [id]: file }, [...state.directories, ...directories], [
      ...directories.map(path => ({ op: "mkdir" as const, path })),
      { op: "replace", path, source: staged.path, size: staged.size, sha256: staged.sha256,
        previous: existing ? { size: existing.size, sha256: existing.sha256 } : null },
    ]);
    return file;
  }
  write(input: string, content: string | Uint8Array, expected?: string) {
    const path = workspacePath(input);
    if (managed(path)) throw new FileError("permission_denied", "Conversation directories are managed", path);
    const frozen = typeof content === "string" ? content : content.slice();
    return this.serialize(() => this.writeLocked(path, frozen, expected));
  }
  writeDocument(input: string, content: string, expected?: string) {
    const path = documentPath(input);
    return this.serialize(() => this.writeLocked(path, content, expected));
  }
  seedDocument(input: string, text: string) {
    const path = documentPath(input);
    return this.serialize(async () => {
      const file = this.resolve(await this.state(), path, false);
      if (file) {
        if (file.binary) throw new FileError("invalid", "Existing Profile document is not UTF-8 text", path);
        return { content: new TextDecoder("utf-8", { fatal: true }).decode(await this.backend.read(file)) };
      }
      await this.writeLocked(path, text);
      return { content: text };
    });
  }
  documentBatch(writes: { path: string; text: string }[], removes: string[]) {
    const changes = writes.map(file => ({ ...file, path: documentPath(file.path) }));
    const deleted = removes.map(documentPath);
    return this.serialize(async () => {
      const state = await this.state(), files = { ...state.files }, directories = new Set(state.directories), operations: WorkspaceMutation[] = [];
      for (const path of deleted) {
        const file = Object.values(files).find(file => file.path === path);
        if (file) { delete files[file.id]; operations.push({ op: "remove", path, directory: false }); }
      }
      for (const { path, text } of changes) {
        const bytes = new TextEncoder().encode(text);
        if (bytes.length > 200 * 1024) throw new FileError("invalid", "Profile document exceeds size limit", path);
        const existing = Object.values(files).find(file => file.path === path);
        if (directories.has(path)) throw new FileError("is_directory", "Profile document is a directory", path);
        const added = this.parents({ ...state, files, directories: [...directories] }, path, true);
        for (const path of added) { directories.add(path); operations.push({ op: "mkdir", path }); }
        const staged = await this.backend.stage(bytes), id = existing?.id ?? await this.identifier(path);
        files[id] = { ...staged, id, path, binary: false, saved: false, mtime: Date.now(), owner: null };
        operations.push({ op: "replace", path, source: staged.path, size: staged.size, sha256: staged.sha256, previous: existing ? { size: existing.size, sha256: existing.sha256 } : null });
      }
      await this.commit(files, [...directories], operations);
    });
  }
  edit(input: string, edits: { oldText: string; newText: string }[], document = false) {
    const path = document ? documentPath(input) : workspacePath(input);
    return this.serialize(async () => {
      const file = this.resolve(await this.state(), path, false);
      if (!file || file.hidden || file.binary) throw new FileError("invalid", "Edit requires an existing text file", path);
      const source = new TextDecoder("utf-8", { fatal: true }).decode(await this.backend.read(file));
      const ranges = edits.map(edit => {
        const start = source.indexOf(edit.oldText);
        if (!edit.oldText || start < 0 || source.indexOf(edit.oldText, start + 1) >= 0) throw new FileError("invalid", "Edit must match exactly once", path);
        return { ...edit, start, end: start + edit.oldText.length };
      }).sort((a, b) => a.start - b.start);
      if (ranges.some((range, index) => index > 0 && ranges[index - 1]!.end > range.start)) throw new FileError("invalid", "Edits overlap", path);
      let text = source;
      for (const range of ranges.reverse()) text = text.slice(0, range.start) + range.newText + text.slice(range.end);
      await this.writeLocked(path, text, source);
    });
  }
  mkdir(input: string, recursive = false) {
    const path = workspacePath(input);
    if (managed(path)) throw new FileError("permission_denied", "Conversation directories are managed", path);
    return this.serialize(async () => {
      const state = await this.state(); this.assertActive(state, path);
      if (this.findPath(state, path)) {
        if (recursive && state.directories.includes(path)) return;
        throw new FileError("invalid", "Destination already exists", path);
      }
      const directories = [...this.parents(state, path, recursive), path];
      await this.commit(state.files, [...state.directories, ...directories], directories.map(path => ({ op: "mkdir", path })));
    });
  }
  remove(input: string, directory = false, recursive = false) {
    const path = workspacePath(input);
    if (managed(path)) throw new FileError("permission_denied", "Use conversation deletion for managed directories", path);
    return this.serialize(async () => {
      const state = await this.state(); this.assertActive(state, path);
      if (Object.values(state.files).some(file => file.hidden && beneath(file.path, path))) throw new FileError("permission_denied", "Private blobs cannot be removed through ox.fs", path);
      const isDirectory = state.directories.includes(path);
      if (directory !== isDirectory) throw new FileError(directory ? "not_directory" : "is_directory", "Entry has the wrong type", path);
      if (!this.findPath(state, path)) throw new FileError("not_found", "File not found", path);
      if (directory && !recursive && [...state.directories, ...Object.values(state.files).map(file => file.path)].some(child => child !== path && beneath(child, path))) throw new FileError("invalid", "Directory is not empty", path);
      await this.removeLocked(state, path);
    });
  }
  private async removeLocked(state: Awaited<ReturnType<ProfileWorkspace["state"]>>, path: string, conversation?: number) {
    const removed = Object.values(state.files).filter(file => beneath(file.path, path) || (conversation !== undefined && file.owner === conversation));
    const ids = new Set(removed.map(file => file.id));
    const directories = state.directories.filter(directory => beneath(directory, path)).sort((a, b) => b.length - a.length);
    await this.commit(Object.fromEntries(Object.entries(state.files).filter(([id]) => !ids.has(id))), state.directories.filter(directory => !beneath(directory, path)), [
      ...removed.map(file => ({ op: "remove" as const, path: file.path, directory: false })),
      ...directories.map(path => ({ op: "remove" as const, path, directory: true })),
    ]);
  }
  move(input: string, destination: string) {
    const source = workspacePath(input), target = workspacePath(destination);
    if (managed(source) || managed(target) || beneath(target, source)) throw new FileError("invalid", "Cannot move managed directories or into the source tree", source);
    return this.serialize(async () => {
      const state = await this.state(); this.assertActive(state, source); this.assertActive(state, target);
      if (Object.values(state.files).some(file => file.hidden && beneath(file.path, source))) throw new FileError("permission_denied", "Private blobs cannot be moved", source);
      if (!this.findPath(state, source)) throw new FileError("not_found", "Source not found", source);
      if (this.findPath(state, target)) throw new FileError("invalid", "Destination already exists", target);
      const added = this.parents(state, target, true);
      const files = { ...state.files }, operations: WorkspaceMutation[] = added.map(path => ({ op: "mkdir", path }));
      const renamedDirectories = state.directories.filter(path => beneath(path, source)).map(path => target + path.slice(source.length));
      operations.push(...renamedDirectories.sort((a, b) => a.length - b.length).map(path => ({ op: "mkdir" as const, path })));
      for (const file of Object.values(files).filter(file => beneath(file.path, source))) {
        const path = target + file.path.slice(source.length);
        operations.push({ op: "move", path, source: file.path, size: file.size, sha256: file.sha256 });
        delete files[file.id];
        const id = await this.identifier(path);
        const { aliases, stamp, ...metadata } = file;
        files[id] = { ...metadata, id, path, owner: owner(path) };
      }
      operations.push(...state.directories.filter(path => beneath(path, source)).sort((a, b) => b.length - a.length).map(path => ({ op: "remove" as const, path, directory: true })));
      await this.commit(files, [...state.directories.filter(path => !beneath(path, source)), ...added, ...renamedDirectories], operations);
    });
  }
  copy(input: string, destination: string) {
    const source = workspacePath(input), target = workspacePath(destination);
    return this.serialize(async () => {
      const state = await this.state(); this.assertActive(state, source); this.assertActive(state, target);
      if (this.findPath(state, target)) throw new FileError("invalid", "Destination already exists", target);
      const file = Object.values(state.files).find(file => file.path === source);
      if (!file || file.hidden) throw new FileError("not_supported", "Copy requires a visible file", source);
      const bytes = await this.backend.read(file);
      return this.writeLocked(target, file.binary ? bytes : new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    });
  }
  saved(input: string, saved: boolean) {
    return this.serialize(async () => {
      const state = await this.state(), file = this.resolve(state, input);
      if (!file || file.hidden) throw new FileError("not_found", "File unavailable", input);
      await this.commit({ ...state.files, [file.id]: { ...file, saved } }, state.directories, []);
    });
  }
  installFileIndex(files: WorkspaceFile[]) {
    return this.serialize(async () => {
      await this.harness.commit(async tx => {
        (await tx.doc(WorkspaceState)).files = Object.fromEntries(files.map(file => [file.id, file]));
      }, context);
    });
  }
  assignArchiveOwners(owners: Map<string, number>) {
    return this.serialize(async () => {
      await this.harness.commit(async tx => {
        const state = await tx.doc(WorkspaceState);
        for (const file of Object.values(state.files)) {
          const id = owners.get(file.path);
          if (file.hidden && file.owner === null && id !== undefined) file.owner = id;
        }
      }, context);
    });
  }
  createConversation(id: ConversationId) {
    return this.serialize(async () => {
      const state = await this.state(), path = `conversations/${id}`;
      if (state.deletedConversations.includes(id)) throw new FileError("not_found", "Conversation was deleted", path);
      if (state.directories.includes(path)) return;
      const directories = ["conversations", path].filter(path => !state.directories.includes(path));
      await this.commit(state.files, [...state.directories, ...directories], directories.map(path => ({ op: "mkdir", path })));
    });
  }
  deleteConversation(id: ConversationId) {
    return this.serialize(async () => {
      await this.harness.commit(async tx => {
        const state = await tx.doc(WorkspaceState);
        if (!state.deletedConversations.includes(id)) state.deletedConversations.push(id);
      }, context);
      await this.removeLocked(await this.state(), `conversations/${id}`, id);
    });
  }
}

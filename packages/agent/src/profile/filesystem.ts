import { err, ok, getOrThrow, ExecutionError, FileError, type ExecutionEnv, type FileInfo, type Result } from "@earendil-works/pi-durable/env";
import { canonical, type ProfileFiles } from "./files";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { OxConversations, ConversationListCursor } from "./conversations";
import { mountedFileSystem, snapshotBinaryReader, type FileBackend, type FileMount } from "../core/file-mounts";
import { bundledSkills } from "../core/bundled-skills";
import { conversationRecordPath, workingFilePath } from "./file-store";

export type ConversationRecords = "measured" | "named" | "excluded";

export function profileMounts(files: ProfileFiles, conversations: OxConversations, snapshot?: Awaited<ReturnType<ProfileFiles["snapshot"]>>, records: ConversationRecords = "measured"): FileMount[] {
  const env = profileEnv(files, conversations, snapshot, records);
  const system = mountedFileSystem("ox-bundled-skills", [{ path: "skills", access: "readOnly", source: { kind: "text", files: Object.fromEntries(
    bundledSkills.flatMap(skill => Object.entries(skill.files).map(([path, text]) => [`${skill.name}/${path}`, text])),
  ) } }]);
  const names = new Set(bundledSkills.map(skill => skill.name));
  const bundled = (path: string) => path.startsWith("skills/") && names.has(path.split("/")[1]!);
  const writable = (path: string) => {
    if (bundled(path)) throw new FileError("permission_denied", "Bundled System skills are read-only; copy to a distinct name to customize", path);
    if (conversationRecordPath(path)) throw new FileError("permission_denied", "Conversation records are read-only", path);
    if (files.physical && !["MEMORY.md", "SOUL.md"].includes(path) && !path.startsWith("skills/")) workingFilePath(path);
  };
  const backend: FileBackend = {
    id: env.id, assertWritable: writable,
    info: async (path, context) => getOrThrow(await (bundled(path) ? system : env).fileInfo(path, context)),
    list: async (path, context) => {
      if (bundled(path)) return getOrThrow(await system.listDir(path, context));
      const entries = getOrThrow(await env.listDir(path, context));
      if (path !== "skills") return entries;
      return [...new Map([...entries, ...getOrThrow(await system.listDir(path, context))].map(entry => [entry.path, entry])).values()].sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    },
    read: async (path, context) => bundled(path) ? getOrThrow(await system.readTextFile(path, context)) : files.physical && !conversationRecordPath(path)
      ? (snapshot ?? files).read(path) : (await files.index())[path]?.binary
        ? getOrThrow(await env.readBinaryFile(path, context)) : getOrThrow(await env.readTextFile(path, context)),
    write: async (path, content, context, expected) => { writable(path); if (files.physical) await files.write(path, content, expected); else getOrThrow(await env.writeFile(path, content, context)); },
    edit: async (path, edits) => { writable(path); await files.edit(path, edits); },
    remove: async (path, context) => { writable(path); getOrThrow(await env.remove(path, undefined, context)); },
    flush: async (path, context) => { writable(path); getOrThrow(await env.flushFile(path, context)); },
    createDirectory: async (path, context, recursive) => { writable(path); if (files.physical) await files.mkdir(path, recursive); else getOrThrow(await env.createDir(path, undefined, context)); },
    removeDirectory: async (path, recursive) => { writable(path); await files.remove(path, true, recursive); },
    move: async (from, to) => { writable(from); writable(to); await files.move(from, to); },
    copy: async (from, to) => { writable(to); await files.copy(from, to); },
  };
  const paths = files.physical ? ["MEMORY.md", "SOUL.md", "skill-selections.json", "skills", ""]
    : ["MEMORY.md", "SOUL.md", "skill-selections.json", "artifacts", "skills", "conversations"];
  return paths.map(path => ({
    path, access: path === "conversations" ? "readOnly" : "readWrite",
    source: { kind: "backend", backend, path },
  }));
}

export function profileEnv(files: ProfileFiles, conversations?: OxConversations, snapshot?: Awaited<ReturnType<ProfileFiles["snapshot"]>>, records: ConversationRecords = "measured"): ExecutionEnv {
  const content = snapshot ?? files;
  const unsupported = async () => err<never, FileError>(new FileError("not_supported", "Operation is unavailable in the Profile filesystem"));
  async function result<T>(body: () => Promise<T>): Promise<Result<T, FileError>> {
    try { return ok(await body()); } catch (error) { return err(error instanceof FileError ? error : new FileError("unknown", String(error))); }
  }
  const isConversation = (name: string) => name === "conversations" || /^conversations\/(0|[1-9][0-9]*)$/.test(name) || conversationRecordPath(name) || (!files.physical && /^conversations\/[0-9]+\/(metadata|history)$/.test(name));
  async function workingEntries(path: string): Promise<FileInfo[]> {
    if (!files.physical) return [];
    try { return await content.list(path); }
    catch (error) { if (error instanceof FileError && error.code === "not_found") return []; throw error; }
  }
  function writable(path: string) {
    if (isConversation(canonical(path))) throw new FileError("permission_denied", "Conversation projections are read-only", path);
  }
  async function conversation(path: string) {
    const match = /^conversations\/(0|[1-9][0-9]*)(?:\/(metadata|history|conversation\.json|turns\.jsonl))?$/.exec(canonical(path));
    if (!conversations || !match || !Number.isSafeInteger(Number(match[1]))) throw new FileError("not_found", "Conversation projection not found", path);
    const reference = conversations.reference(Number(match[1]) as ConversationId);
    if (!await conversations.visible(reference)) throw new FileError("not_found", "Conversation projection not found", path);
    if (files.physical && match[2] && (await content.record(canonical(path), false))) throw new FileError("invalid", "A retained working file conflicts with this virtual conversation record; storage preparation is required", path);
    return { reference, file: match[2] };
  }
  async function info(path: string): Promise<FileInfo> {
    const name = canonical(path);
    if (isConversation(name)) {
      if (name === "conversations" && conversations) return { name, path: "/conversations", kind: "directory", size: 0, mtimeMs: 0 };
      const projection = await conversation(name);
      return { name: name.split("/").at(-1)!, path: "/" + name, kind: projection.file ? "file" : "directory",
        size: projection.file ? new TextEncoder().encode(await text(name)).length : 0, mtimeMs: 0 };
    }
    if (files.physical) return content.info(name);
    const index = await files.index();
    if (index[name]) return { name: name.split("/").at(-1)!, path: "/" + name, kind: "file", size: index[name].size, mtimeMs: index[name].mtime };
    if (!name || ["artifacts", "skills"].includes(name) || Object.keys(index).some(key => key.startsWith(name + "/"))) {
      return { name: name.split("/").at(-1) ?? "", path: "/" + name, kind: "directory", size: 0, mtimeMs: 0 };
    }
    throw new FileError("not_found", "File not found", path);
  }
  async function text(path: string) {
    if (isConversation(canonical(path))) {
      const projection = await conversation(path);
      if (!projection.file) throw new FileError("is_directory", "Cannot read a conversation directory", path);
      if (projection.file === "turns.jsonl") {
        const entries = [];
        let cursor;
        let bytes = 0;
        do {
          const page = await conversations!.history(projection.reference, 100, cursor);
          for (const entry of page.items) {
            const line = JSON.stringify(entry);
            bytes += new TextEncoder().encode(line).length + 1;
            if (bytes > 32 * 1024 * 1024) throw new FileError("invalid", "Transcript exceeds read safety limit; use paginated conversation history", path);
            entries.push(line);
          }
          cursor = page.next;
        } while (cursor);
        return entries.reverse().join("\n") + (entries.length ? "\n" : "");
      }
      const value = JSON.stringify(["metadata", "conversation.json"].includes(projection.file) ? await conversations!.metadata(projection.reference) : await conversations!.history(projection.reference));
      if (new TextEncoder().encode(value).length > 200 * 1024) throw new FileError("invalid", "Projection exceeds read limit; use paginated history with a smaller page", path);
      return value;
    }
    const value = await content.read(path);
    if (typeof value !== "string") throw new FileError("invalid", "Binary files require a dedicated image/document operation", path);
    return value;
  }
  return {
    id: `ox-profile:${files.identity}`, cwd: "/",
    absolutePath: async path => result(async () => "/" + canonical(path)),
    canonicalPath: async path => result(async () => "/" + canonical(path)),
    joinPath: async parts => result(async () => "/" + canonical(parts.filter(part => part !== "/").join("/"))),
    fileInfo: async path => result(() => info(path)),
    exists: async path => result(async () => {
      try { await info(path); return true; } catch (error) { if (error instanceof FileError && error.code === "not_found") return false; throw error; }
    }),
    readTextFile: async path => result(() => text(path)),
    readBinaryFile: async path => result(async () => { const value = isConversation(canonical(path)) ? await text(path) : await files.read(path); return typeof value === "string" ? new TextEncoder().encode(value) : value; }),
    openBinaryReader: async (path, options) => result(async () => {
      const metadata = await info(path);
      if (metadata.kind === "directory") throw new FileError("is_directory", "Cannot read a directory", path);
      if (metadata.kind === "symlink" && options?.noFollow) throw new FileError("invalid", "Cannot open a symbolic link", path);
      return snapshotBinaryReader(metadata, isConversation(canonical(path)) ? await text(path) : await content.read(path));
    }),
    openDirReader: unsupported, watch: unsupported,
    readTextLines: async (path, options) => result(async () => (await text(path)).split("\n").slice(0, options?.maxLines)),
    openTextLineReader: async path => result(async () => {
      const value = await text(path);
      const lines = value === "" ? [] : value.split("\n");
      if (value.endsWith("\n")) lines.pop();
      let index = 0;
      let closed = false;
      return { readLine: async () => closed ? err(new FileError("invalid", "Reader closed")) : ok(index < lines.length ?
        { text: lines[index++], terminated: index < lines.length || value.endsWith("\n") } : undefined), close: async () => { closed = true; } };
    }),
    listDir: async path => result(async () => {
      if ((await info(path)).kind !== "directory") throw new FileError("not_directory", "Not a directory", path);
      const name = canonical(path); const prefix = name ? name + "/" : "";
      if (isConversation(name)) {
        if (name !== "conversations") {
          if (records === "excluded") return workingEntries(name);
          const children = ["conversation.json", "turns.jsonl"];
          const entries = records === "measured" ? await Promise.all(children.map(child => info(prefix + child)))
            : children.map(child => ({ name: child, path: `/${prefix}${child}`, kind: "file" as const, size: 0, mtimeMs: 0 }));
          return [...await workingEntries(name), ...entries];
        }
        const children: FileInfo[] = [];
        let cursor: ConversationListCursor | undefined;
        do {
          const page = await conversations!.references(100, cursor);
          children.push(...page.items.map(reference => ({ name: String(reference.conversationID), path: `/conversations/${reference.conversationID}`,
            kind: "directory" as const, size: 0, mtimeMs: 0 })));
          cursor = page.next;
        } while (cursor);
        return [...new Map([...await workingEntries(name), ...children].map(entry => [entry.path, entry])).values()];
      }
      if (files.physical) {
        const entries = await content.list(name);
        if (!name && conversations && !entries.some(entry => entry.name === "conversations")) entries.push(await info("conversations"));
        return entries;
      }
      const children = new Set(Object.keys(await files.index()).filter(key => key.startsWith(prefix)).map(key => key.slice(prefix.length).split("/")[0]));
      if (!name) { children.add("artifacts"); children.add("skills"); if (conversations) children.add("conversations"); }
      return Promise.all([...children].sort().map(child => info(prefix + child)));
    }),
    writeFile: async (path, content) => result(async () => { writable(path); await files.write(path, content); }),
    remove: async path => result(async () => { writable(path); await files.remove(path); }),
    createDir: async path => result(async () => { writable(path); canonical(path); /* directories are implicit; write validates the writable namespace */ }),
    flushFile: async path => result(async () => { writable(path); await files.flushFile(path); }), // Native artifact durability, or an already committed Pi document.
    appendFile: unsupported, truncateFile: unsupported, renameFile: unsupported,
    createTempDir: unsupported, createTempFile: unsupported,
    exec: async () => err(new ExecutionError("shell_unavailable", "Shell execution is unavailable")),
    cleanup: async () => {},
  };
}

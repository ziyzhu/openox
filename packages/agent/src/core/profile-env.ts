import { err, ok, ExecutionError, FileError, type ExecutionEnv, type FileInfo, type Result } from "@earendil-works/pi-durable/env";
import { canonical, type ProfileFiles } from "./profile-files";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { OxConversations, ConversationListCursor } from "./conversations";

export function profileEnv(files: ProfileFiles, conversations?: OxConversations): ExecutionEnv {
  const unsupported = async () => err<never, FileError>(new FileError("not_supported", "Operation is unavailable in the Profile filesystem"));
  async function result<T>(body: () => Promise<T>): Promise<Result<T, FileError>> {
    try { return ok(await body()); } catch (error) { return err(error instanceof FileError ? error : new FileError("unknown", String(error))); }
  }
  const isConversation = (name: string) => name === "conversations" || name.startsWith("conversations/");
  function projectionPath(path: string) {
    const name = canonical(path);
    return name === "chats" ? "conversations" : name.startsWith("chats/") ? "conversations/" + name.slice(6) : name;
  }
  function writable(path: string) {
    if (isConversation(projectionPath(path))) throw new FileError("permission_denied", "Conversation projections are read-only", path);
  }
  async function conversation(path: string) {
    const match = /^conversations\/(0|[1-9][0-9]*)(?:\/(metadata|history))?$/.exec(projectionPath(path));
    if (!conversations || !match || !Number.isSafeInteger(Number(match[1]))) throw new FileError("not_found", "Conversation projection not found", path);
    const reference = conversations.reference(Number(match[1]) as ConversationId);
    let metadata;
    try { metadata = await conversations.metadata(reference); }
    catch (error) { if (error instanceof Error && error.message === "Conversation not found") throw new FileError("not_found", error.message, path); throw error; }
    if (!metadata.presentation?.visible) throw new FileError("not_found", "Conversation projection not found", path);
    return { reference, metadata, file: match[2] };
  }
  async function info(path: string): Promise<FileInfo> {
    const name = projectionPath(path);
    if (isConversation(name)) {
      if (name === "conversations" && conversations) return { name, path: "/conversations", kind: "directory", size: 0, mtimeMs: 0 };
      const projection = await conversation(name);
      return { name: name.split("/").at(-1)!, path: "/" + name, kind: projection.file ? "file" : "directory",
        size: projection.file ? new TextEncoder().encode(await text(name)).length : 0, mtimeMs: 0 };
    }
    const index = await files.index();
    if (index[name]) return { name: name.split("/").at(-1)!, path: "/" + name, kind: "file", size: index[name].size, mtimeMs: index[name].mtime };
    if (!name || ["artifacts", "skills"].includes(name) || Object.keys(index).some(key => key.startsWith(name + "/"))) {
      return { name: name.split("/").at(-1) ?? "", path: "/" + name, kind: "directory", size: 0, mtimeMs: 0 };
    }
    throw new FileError("not_found", "File not found", path);
  }
  async function text(path: string) {
    if (isConversation(projectionPath(path))) {
      const projection = await conversation(path);
      if (!projection.file) throw new FileError("is_directory", "Cannot read a conversation directory", path);
      // History is a bounded page of the FULL ledger. The scoped next cursor is consumed through
      // Session.conversations.history / the adapter history command; no context truncation is hidden.
      const value = JSON.stringify(projection.file === "metadata" ? projection.metadata : await conversations!.history(projection.reference));
      if (new TextEncoder().encode(value).length > 200 * 1024) throw new FileError("invalid", "Projection exceeds read limit; use paginated history with a smaller page", path);
      return value;
    }
    const value = await files.read(path);
    if (typeof value !== "string") throw new FileError("invalid", "Binary artifacts require a dedicated image/document operation", path);
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
    readBinaryFile: async path => result(async () => { const value = isConversation(projectionPath(path)) ? await text(path) : await files.read(path); return typeof value === "string" ? new TextEncoder().encode(value) : value; }),
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
      const name = projectionPath(path); const prefix = name ? name + "/" : "";
      if (isConversation(name)) {
        if (name !== "conversations") return Promise.all(["metadata", "history"].map(child => info(prefix + child)));
        const children: FileInfo[] = [];
        let cursor: ConversationListCursor | undefined;
        do {
          const page = await conversations!.list(100, cursor);
          children.push(...page.items.map(item => ({ name: String(item.reference.conversationID), path: `/conversations/${item.reference.conversationID}`,
            kind: "directory" as const, size: 0, mtimeMs: 0 })));
          cursor = page.next;
        } while (cursor);
        return children;
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

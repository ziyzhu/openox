import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import { FileError, type FileInfo } from "@earendil-works/pi-durable/env";
import type { ProfileRuntime } from "../../profile/runtime";
import { mountedFileSystem, type FileBackend, type FileMount } from "../../core/file-mounts";
import { canonical } from "../../core/file-paths";
import { encodeBase64 } from "../../core/base64";
import type { FileOperation, FileRequest } from "../../core/filesystem";
import { native } from "./bridge";
import { conversationRecordPath } from "../../profile/file-store";
import { profileMounts } from "../../profile/filesystem";

export interface NativeFileMount { path: string; access: "readOnly" | "readWrite" }
export async function invokeFilesystem(runtime: ProfileRuntime, capability: string, mounts: NativeFileMount[], operation: FileOperation, args: FileRequest, signal: AbortSignal) {
  if (!capability || !Array.isArray(mounts) || !["list", "read", "write", "edit", "rm", "mkdir", "move", "copy", "glob", "grep"].includes(operation)) throw new Error("Invalid filesystem capability");
  const context = withAbortSignal(signal, BACKGROUND_CONTEXT);
  const originals = new Map<string, string>();
  const call = async <T>(op: string, path: string, values: object = {}) => {
    signal.throwIfAborted();
    const result = await native<{ value?: T; error?: { code: ConstructorParameters<typeof FileError>[0]; message: string } }>("fileBackend", { capability, op, path, ...values }, signal);
    signal.throwIfAborted();
    if (result.error) throw new FileError(result.error.code, result.error.message, path);
    return result.value!;
  };
  const backend: FileBackend = {
    id: "ios-files:" + runtime.conversations.profileID,
    info: path => call<FileInfo>("info", path),
    list: path => call<FileInfo[]>("list", path),
    read: async path => {
      const result = await call<{ text: string | null; unsupported: string | null; truncated: boolean }>("read", path);
      if (result.unsupported || result.text === null) throw new FileError("not_supported", result.unsupported ?? "File is not readable text", path);
      if (result.truncated) throw new FileError("invalid", "Source exceeds the filesystem read safety limit", path);
      if (operation === "edit") originals.set(path, result.text);
      return result.text;
    },
    write: async (path, content, _context, expected) => {
      await call("write", path, typeof content === "string" ? { content, expected: expected ?? originals.get(path) } : { base64: encodeBase64(content) });
    },
    remove: async path => { await call("rm", path); },
    createDirectory: async (path, _context, recursive) => { await call("mkdir", path, { recursive: recursive ?? false }); },
    removeDirectory: async (path, recursive) => { await call("rm", path, { recursive }); },
    move: async (from, to) => { await call("move", from, { to }); },
    copy: async (from, to) => { await call("copy", from, { to }); },
  };
  const inputs: FileMount[] = mounts.filter(mount => mount.path !== "" && (!runtime.files.physical || !["artifacts", "conversations"].includes(mount.path))).map(mount => ({ ...mount, visibility: mount.path === "history" ? "unlisted" : "listed",
    source: { kind: "backend", backend, path: mount.path } }));
  if (runtime.files.physical) {
    const search = operation === "glob" || operation === "grep";
    const base = canonical(args.path ?? "");
    const includeConversationRecords = operation !== "grep" || base === "conversations" || base.startsWith("conversations/");
    const profileInputs = search ? profileMounts(runtime.files, runtime.conversations, await runtime.files.snapshot(signal, base), includeConversationRecords) : runtime.env.mounts;
    for (const mount of profileInputs.filter(mount => mount.path === "")) {
      if (mount.source.kind !== "backend") throw new Error("Invalid Profile file mount");
      const profile = mount.source.backend;
      inputs.push({ ...mount, source: { ...mount.source, backend: { ...profile,
        read: async (path, context) => {
          if (conversationRecordPath(path)) await profile.info(path, context);
          return operation === "read" || conversationRecordPath(path) ? backend.read(path, context) : profile.read(path, context);
        },
      } } });
    }
  }
  inputs.push(...runtime.textMounts.mounts.map(mount => ({ path: mount.path, access: mount.access, source: { kind: "text" as const, files: mount.files } })));
  const env = mountedFileSystem(runtime.conversations.profileID, inputs);
  try {
    const result = await runtime.filesystem.invoke(env, operation, args, context);
    if (operation === "read" && /^skills\/[^/]+\/SKILL\.md$/.test(canonical(args.path ?? ""))) await call("activate", canonical(args.path!));
    return result;
  } catch (error) {
    if (operation === "read" && error instanceof FileError && error.code === "not_supported") return { path: canonical(args.path!), text: null, truncated: false, unsupported: error.message, nextOffset: null, diagnostics: [] };
    throw error;
  } finally { await env.cleanup(BACKGROUND_CONTEXT); }
}

import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import { FileError, type FileInfo } from "@earendil-works/pi-durable/env";
import type { ProfileRuntime } from "../../profile/runtime";
import { mountedFileSystem, type FileBackend, type FileMount } from "../../core/file-mounts";
import { canonical } from "../../core/file-paths";
import type { FileOperation, FileRequest } from "../../core/filesystem";
import { native } from "./bridge";

export interface NativeFileMount { path: string; access: "readOnly" | "readWrite" }
export async function invokeFilesystem(runtime: ProfileRuntime, capability: string, mounts: NativeFileMount[], operation: FileOperation, args: FileRequest, signal: AbortSignal) {
  if (!capability || !Array.isArray(mounts) || !["list", "read", "write", "edit", "delete", "glob", "grep"].includes(operation)) throw new Error("Invalid filesystem capability");
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
    write: async (path, content) => {
      if (typeof content !== "string") throw new FileError("not_supported", "Use explicit media publication for binary files", path);
      await call("write", path, { content, expected: originals.get(path) });
    },
    remove: async path => { await call("delete", path); },
  };
  const inputs: FileMount[] = mounts.map(mount => ({ ...mount, source: { kind: "backend", backend, path: mount.path } }));
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

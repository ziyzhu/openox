import type { Context } from "@earendil-works/chord";
import { err, ok, FileError, ExecutionError, type ExecutionEnv, type FileInfo, type Result } from "@earendil-works/pi-durable/env";
import { canonical } from "./file-paths";

export interface FileBackend {
  readonly id: string;
  assertWritable?(path: string): void;
  info(path: string, context: Context): Promise<FileInfo>;
  list(path: string, context: Context): Promise<FileInfo[]>;
  read(path: string, context: Context): Promise<string | Uint8Array>;
  write?(path: string, content: string | Uint8Array, context: Context, expected?: string): Promise<void>;
  edit?(path: string, edits: { oldText: string; newText: string }[], context: Context): Promise<void>;
  remove?(path: string, context: Context): Promise<void>;
  flush?(path: string, context: Context): Promise<void>;
  createDirectory?(path: string, context: Context, recursive?: boolean): Promise<void>;
  removeDirectory?(path: string, recursive: boolean, context: Context): Promise<void>;
  move?(from: string, to: string, context: Context): Promise<void>;
  copy?(from: string, to: string, context: Context): Promise<void>;
}
export type FileMount = {
  readonly path: string;
  readonly visibility?: "listed" | "unlisted";
} & ({ readonly access: "readOnly"; readonly source: { readonly kind: "text"; readonly files: Readonly<Record<string, string>> } }
  | { readonly access: "readOnly" | "readWrite"; readonly source: { readonly kind: "backend"; readonly backend: FileBackend; readonly path?: string } });
export interface TextFileMount {
  path: string;
  access: "readOnly";
  files: Readonly<Record<string, string>>;
}
export interface MountedExecutionEnv extends ExecutionEnv {
  readonly mounts: readonly FileMount[];
  assertWritable(path: string): void;
  editFile(path: string, edits: { oldText: string; newText: string }[], context: Context): Promise<Result<void, FileError>>;
  writeChecked(path: string, content: string, expected: string, context: Context): Promise<Result<void, FileError>>;
  removeDirectory(path: string, recursive: boolean, context: Context): Promise<Result<void, FileError>>;
  transfer(from: string, to: string, copy: boolean, context: Context): Promise<Result<void, FileError>>;
}

function freezeTextFiles(files: Readonly<Record<string, string>>) {
  if (!files || typeof files !== "object" || Array.isArray(files) || Object.values(files).some(text => typeof text !== "string")) throw new FileError("invalid", "Text mount files must contain strings");
  return Object.freeze(Object.assign(Object.create(null) as Record<string, string>, files));
}

function textBackend(spec: TextFileMount): FileBackend {
  const files = spec.files;
  const paths = Object.keys(files).sort();
  if (![spec.path, ...paths].every(path => path.split("/").every(part => /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(part))) || paths.some(path => !path || canonical(path) !== path || paths.some(other => other.startsWith(path + "/")))) throw new FileError("invalid", "Invalid text mount inventory");
  const info = async (path: string): Promise<FileInfo> => {
    const text = files[path];
    if (typeof text === "string" || !path || paths.some(file => file.startsWith(path + "/"))) {
      return { path: "/" + path, name: path.split("/").at(-1) ?? "", kind: typeof text === "string" ? "file" : "directory",
        size: typeof text === "string" ? new TextEncoder().encode(text).length : 0, mtimeMs: 0 };
    }
    throw new FileError("not_found", "File not found", path);
  };
  return {
    id: `text:${spec.path}`, info,
    list: async path => {
      if ((await info(path)).kind !== "directory") throw new FileError("not_directory", "Not a directory", path);
      const prefix = path ? path + "/" : "";
      const children = new Set(paths.filter(file => file.startsWith(prefix)).map(file => file.slice(prefix.length).split("/")[0]!));
      return Promise.all([...children].sort().map(child => info(prefix + child)));
    },
    read: async path => {
      if ((await info(path)).kind === "directory") throw new FileError("is_directory", "Cannot read a directory", path);
      return files[path]!;
    },
  };
}

export function mountedFileSystem(scope: string, inputs: readonly FileMount[]): MountedExecutionEnv {
  if (!scope) throw new FileError("invalid", "Filesystem scope identity is required");
  const mounts = Object.freeze(inputs.map(mount => {
    const path = canonical(mount.path);
    if (path !== mount.path || !["readOnly", "readWrite"].includes(mount.access)) throw new FileError("invalid", "Invalid filesystem mount", mount.path);
    const source = mount.source.kind === "text" ? Object.freeze({ kind: "text" as const, files: freezeTextFiles(mount.source.files) }) : Object.freeze({ ...mount.source });
    if (source.kind === "text" && mount.access !== "readOnly") throw new FileError("invalid", "Text mounts must be read-only", path);
    const backend = source.kind === "text" ? textBackend({ path, access: "readOnly", files: source.files }) : source.backend;
    if (!backend.id) throw new FileError("invalid", "Backend identity is required", path);
    return Object.freeze({ ...mount, source, path, backend, backendPath: canonical(source.kind === "backend" ? source.path ?? "" : "") }) as FileMount & { backend: FileBackend; backendPath: string };
  }));
  for (const mount of mounts) for (const other of mounts) {
    if (mount !== other && (mount.path === other.path || (other.path && mount.path.startsWith(other.path + "/")))) throw new FileError("invalid", `Overlapping filesystem mounts: ${mount.path} and ${other.path}`);
  }
  let closed = false;
  const path = (input: string) => { if (closed) throw new FileError("invalid", "Filesystem view is closed"); return canonical(input); };
  const route = (input: string, mutation = false) => {
    const name = path(input);
    const mount = mounts.find(mount => mount.path && (name === mount.path || name.startsWith(mount.path + "/"))) ?? mounts.find(mount => mount.path === "");
    if (!mount) throw new FileError("not_found", "No mount owns this path", input);
    if (mutation && mount.access !== "readWrite") throw new FileError("permission_denied", "Mount is read-only", input);
    const relative = !mount.path ? name : name === mount.path ? "" : name.slice(mount.path.length + 1);
    const target = [mount.backendPath, relative].filter(Boolean).join("/");
    if (mutation) mount.backend.assertWritable?.(target);
    return { mount, name, target };
  };
  const result = async <T>(body: () => Promise<T>): Promise<Result<T, FileError>> => {
    try { return ok(await body()); } catch (error) { return err(error instanceof FileError ? error : new FileError("unknown", error instanceof Error ? error.message : String(error), undefined, error instanceof Error ? error : undefined)); }
  };
  const call = <T>(input: string, mutation: boolean, body: (backend: FileBackend, target: string) => Promise<T>) =>
    result(async () => { const { mount, target } = route(input, mutation); return body(mount.backend, target); });
  const info = async (input: string, context: Context): Promise<FileInfo> => {
    const name = path(input);
    if (!name || mounts.some(mount => mount.path.startsWith(name + "/"))) return { name: name.split("/").at(-1) ?? "", path: "/" + name, kind: "directory", size: 0, mtimeMs: 0 };
    const { mount, target } = route(input);
    return { ...await mount.backend.info(target, context), name: name.split("/").at(-1)!, path: "/" + name };
  };
  const text = async (input: string, context: Context) => {
    const { mount, target } = route(input);
    const content = await mount.backend.read(target, context);
    if (typeof content !== "string") throw new FileError("invalid", "Binary files require a dedicated image/document operation", input);
    return content;
  };
  const unavailable = async () => err<never, FileError>(new FileError("not_supported", "Operation is unavailable in the mounted filesystem"));
  return {
    id: JSON.stringify([scope, mounts.map(mount => [mount.path, mount.access, mount.backend.id, mount.backendPath])]), cwd: "/", mounts,
    assertWritable: input => { route(input, true); },
    absolutePath: async input => result(async () => "/" + path(input)),
    canonicalPath: async input => result(async () => "/" + path(input)),
    joinPath: async parts => result(async () => "/" + path(parts.filter(part => part !== "/").join("/"))),
    fileInfo: async (input, context) => result(() => info(input, context)),
    exists: async (input, context) => result(async () => {
      try { await info(input, context); return true; } catch (error) { if (error instanceof FileError && error.code === "not_found") return false; throw error; }
    }),
    listDir: async (input, context) => result(async () => {
      const name = path(input);
      if ((await info(input, context)).kind !== "directory") throw new FileError("not_directory", "Not a directory", input);
      const prefix = name ? name + "/" : "";
      const children = mounts.filter(mount => mount.visibility !== "unlisted" && mount.path.startsWith(prefix)).map(mount => mount.path.slice(prefix.length).split("/")[0]!);
      const fallback = mounts.find(mount => mount.path === "");
      if (children.length && (!name || !fallback)) {
        const entries = fallback && !name ? await fallback.backend.list(fallback.backendPath, context) : [];
        const projected = (await Promise.all([...new Set(children)].filter(Boolean).sort().map(async child => {
          try { return await info(prefix + child, context); } catch (error) { if (error instanceof FileError && error.code === "not_found") return undefined; throw error; }
        }))).filter((entry): entry is FileInfo => entry !== undefined);
        return [...new Map([...entries, ...projected].map(entry => [entry.path, entry])).values()].sort((a, b) => a.name.localeCompare(b.name));
      }
      const { mount, target } = route(input);
      const entries = await mount.backend.list(target, context);
      return entries.map(entry => {
        const child = canonical(entry.path);
        const base = target ? target + "/" : "";
        if (!child.startsWith(base) || !child.slice(base.length) || child.slice(base.length).includes("/")) throw new FileError("invalid", "Backend returned an entry outside its directory", input);
        const virtual = prefix + child.slice(base.length);
        return { ...entry, path: "/" + virtual, name: virtual.split("/").at(-1)! };
      });
    }),
    readTextFile: async (input, context) => result(() => text(input, context)),
    readBinaryFile: async (input, context) => call(input, false, async (backend, target) => {
      const content = await backend.read(target, context);
      return typeof content === "string" ? new TextEncoder().encode(content) : content;
    }),
    readTextLines: async (input, options, context) => result(async () => (await text(input, context)).split("\n").slice(0, options?.maxLines)),
    openTextLineReader: async (input, context) => result(async () => {
      const value = await text(input, context);
      const lines = value === "" ? [] : value.split("\n");
      if (value.endsWith("\n")) lines.pop();
      let index = 0;
      let ended = false;
      return { readLine: async () => ended || closed ? err(new FileError("invalid", "Reader closed")) : ok(index < lines.length ?
        { text: lines[index++], terminated: index < lines.length || value.endsWith("\n") } : undefined), close: async () => { ended = true; } };
    }),
    writeFile: async (input, content, context) => call(input, true, async (backend, target) => {
      if (!backend.write) throw new FileError("not_supported", "Mount does not support writes", input);
      await backend.write(target, content, context);
    }),
    writeChecked: async (input, content, expected, context) => call(input, true, async (backend, target) => {
      if (!backend.write) throw new FileError("not_supported", "Mount does not support writes", input);
      await backend.write(target, content, context, expected);
    }),
    editFile: async (input, edits, context) => call(input, true, async (backend, target) => {
      if (!backend.edit) throw new FileError("not_supported", "Mount does not support atomic edits", input);
      await backend.edit(target, edits, context);
    }),
    remove: async (input, _options, context) => call(input, true, async (backend, target) => {
      if (!backend.remove) throw new FileError("not_supported", "Mount does not support removal", input);
      await backend.remove(target, context);
    }),
    flushFile: async (input, context) => call(input, true, async (backend, target) => {
      if (!backend.flush) throw new FileError("not_supported", "Mount does not support flush", input);
      await backend.flush(target, context);
    }),
    removeDirectory: async (input, recursive, context) => call(input, true, async (backend, target) => {
      if (!backend.removeDirectory) throw new FileError("not_supported", "Mount does not support directory removal", input);
      await backend.removeDirectory(target, recursive, context);
    }),
    transfer: async (from, to, copy, context) => result(async () => {
      const source = route(from, !copy), destination = route(to, true);
      if (source.mount.backend !== destination.mount.backend) throw new FileError("not_supported", "Transfers across filesystem mounts are unavailable", from);
      const operation = copy ? source.mount.backend.copy : source.mount.backend.move;
      if (!operation) throw new FileError("not_supported", "Mount does not support this transfer", from);
      await operation(source.target, destination.target, context);
    }),
    createDir: async (input, options, context) => result(async () => {
      const name = path(input);
      if (!name || mounts.some(mount => mount.path.startsWith(name + "/"))) throw new FileError("permission_denied", "Mount roots are managed", input);
      const { mount, target } = route(input, true);
      if (mount.backend.createDirectory) await mount.backend.createDirectory(target, context, options?.recursive);
      else if ((await mount.backend.info(target, context)).kind !== "directory") throw new FileError("not_directory", "Mount does not support directory creation", input);
    }),
    appendFile: unavailable, truncateFile: unavailable, renameFile: unavailable,
    createTempDir: unavailable, createTempFile: unavailable,
    exec: async () => err(new ExecutionError("shell_unavailable", "Shell execution is unavailable")),
    cleanup: async () => { closed = true; },
  };
}

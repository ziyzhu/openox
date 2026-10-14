import { FileError, type FileInfo } from "@earendil-works/pi-durable/env";
import type { FileBackend } from "../src/core/file-mounts";
import { canonical } from "../src/core/file-paths";

export function memoryFiles(seed: Record<string, string> = {}): FileBackend {
  const files = new Map(Object.entries(seed).map(([path, text]) => [canonical(path), text]));
  const directories = new Set([""]);
  const parent = (path: string) => path.split("/").slice(0, -1).join("/");
  for (const path of files.keys()) { let directory = parent(path); while (directory) { directories.add(directory); directory = parent(directory); } }
  const info = async (path: string): Promise<FileInfo> => {
    if (!files.has(path) && !directories.has(path)) throw new FileError("not_found", "File not found", path);
    return { name: path.split("/").at(-1) ?? "", path: "/" + path, kind: files.has(path) ? "file" : "directory", size: Buffer.byteLength(files.get(path) ?? ""), mtimeMs: 0 };
  };
  const requireParent = (path: string) => { if (!directories.has(parent(path))) throw new FileError("not_found", "Parent directory not found", path); };
  const transfer = async (from: string, to: string, move: boolean) => {
    await info(from); requireParent(to);
    if (files.has(to) || directories.has(to) || to.startsWith(from + "/")) throw new FileError("invalid", "Destination exists or is inside source", to);
    const selected = [...files].filter(([path]) => path === from || path.startsWith(from + "/"));
    const selectedDirectories = [...directories].filter(path => path === from || path.startsWith(from + "/"));
    for (const [path, text] of selected) { files.set(to + path.slice(from.length), text); if (move) files.delete(path); }
    for (const path of selectedDirectories) { directories.add(to + path.slice(from.length)); if (move) directories.delete(path); }
  };
  return {
    id: "eval-working-files", info,
    list: async path => { if ((await info(path)).kind !== "directory") throw new FileError("not_directory", "Expected directory", path); return Promise.all([...new Set([...files.keys(), ...directories])].filter(child => child !== path && parent(child) === path).sort().map(info)); },
    read: async path => { if ((await info(path)).kind !== "file") throw new FileError("is_directory", "Expected file", path); return files.get(path)!; },
    write: async (path, content, _context, expected) => { requireParent(path); if (directories.has(path)) throw new FileError("is_directory", "Expected file", path); if (expected !== undefined && files.get(path) !== expected) throw new FileError("invalid", "File changed after reading", path); if (typeof content !== "string") throw new FileError("not_supported", "Text fixture required", path); files.set(path, content); },
    remove: async path => { if ((await info(path)).kind !== "file") throw new FileError("is_directory", "Expected file", path); files.delete(path); },
    createDirectory: async (path, _context, recursive) => { if (files.has(path)) throw new FileError("invalid", "File already exists", path); if (recursive) { const parts = path.split("/"); for (let index = 1; index <= parts.length; index++) { const ancestor = parts.slice(0,index).join("/"); if (files.has(ancestor)) throw new FileError("not_directory", "Parent is a file", ancestor); } for (let index = 1; index <= parts.length; index++) directories.add(parts.slice(0,index).join("/")); } else { requireParent(path); if (directories.has(path)) throw new FileError("invalid", "Directory already exists", path); directories.add(path); } },
    removeDirectory: async (path, recursive) => { if (!path || (await info(path)).kind !== "directory") throw new FileError("not_directory", "Expected non-root directory", path); const children = [...files.keys(),...directories].filter(child=>child.startsWith(path+"/")); if (children.length && !recursive) throw new FileError("invalid", "Directory is not empty", path); for (const child of children) { files.delete(child); directories.delete(child); } directories.delete(path); },
    copy: (from,to) => transfer(from,to,false), move: (from,to) => transfer(from,to,true),
  };
}

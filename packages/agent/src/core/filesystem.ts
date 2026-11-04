import type { Context } from "@earendil-works/chord";
import type { ToolExecutionApi, ToolExecutionResult } from "@earendil-works/pi-durable";
import { createReadTool, createWriteTool, createEditTool } from "@earendil-works/pi-durable/tools";
import { getOrThrow, FileError, type FileInfo } from "@earendil-works/pi-durable/env";
import { Value } from "typebox/value";
import { RE2JS } from "re2js";
import type { MountedExecutionEnv } from "./file-mounts";
import { canonical } from "./file-paths";
import { filesystemContract } from "./filesystem-contract";
import { bundledSkills } from "./bundled-skills";
import { decodeBase64 } from "./base64";

const tools = { read: createReadTool(), write: createWriteTool(), edit: createEditTool() };
export type FileOperation = "stat" | "list" | "read" | "write" | "edit" | "rm" | "mkdir" | "move" | "copy" | "glob" | "grep";
export interface FileRequest {
  path?: string; from?: string; to?: string; recursive?: boolean; purpose?: string; offset?: number; limit?: number; content?: string; base64?: string;
  edits?: { oldText: string; newText: string }[]; pattern?: string; cursor?: string;
  options?: { limit?: number; glob?: string; ignoreCase?: boolean; literal?: boolean; contextLines?: number };
}
type SearchMatch = { path: string; line: number; text: string; before: string[]; after: string[] };
type FilePosition = { path: string; line?: number; size?: number; mtimeMs?: number };
type Candidates = { paths: string[]; truncated: boolean; diagnostics: { path: string; message: string }[]; nextPath: string | null };
const maximumFiles = 1_000;
const maximumEntries = 10_000;
const mutations = new Set(["write", "edit", "rm", "mkdir", "move", "copy"]);
const immutableRoots = new Set(bundledSkills.map(skill => `skills/${skill.name}`));
const encoder = new TextEncoder();
const item = (info: FileInfo & { cloud?: string | null }) => ({ path: canonical(info.path), name: info.name, type: info.kind,
  size: info.kind === "directory" ? null : info.size, mtimeMs: info.mtimeMs || null, cloud: info.cloud ?? null });
const limit = (value: number | undefined, fallback: number, maximum: number) => {
  if (value !== undefined && (!Number.isSafeInteger(value) || value < 1 || value > maximum)) throw new FileError("invalid", "Invalid filesystem limit");
  return value ?? fallback;
};
function comparePaths(left: string, right: string) {
  const a = left.split("/"), b = right.split("/");
  for (let index = 0; index < Math.min(a.length, b.length); index++) {
    if (a[index] !== b[index]) return a[index]! < b[index]! ? -1 : 1;
  }
  return a.length - b.length;
}
function cursorQuery(env: MountedExecutionEnv, operation: FileOperation, args: FileRequest) {
  const options = args.options ?? {};
  return JSON.stringify([1, env.id, operation, args.path, args.pattern ?? null, options.limit ?? (operation === "list" ? 50 : 100),
    options.glob ?? null, options.ignoreCase ?? false, options.literal ?? false, options.contextLines ?? 0]);
}
function cursorPosition(env: MountedExecutionEnv, operation: FileOperation, args: FileRequest): FilePosition | undefined {
  if (args.cursor === undefined) return;
  try {
    const value = JSON.parse(args.cursor);
    if (value.query !== cursorQuery(env, operation, args) || typeof value.path !== "string" || value.path.length > 4_096
      || canonical(value.path) !== value.path || (args.path && value.path !== args.path && !value.path.startsWith(args.path + "/"))
      || Object.keys(value).some(key => !["query", "path", "line", "size", "mtimeMs"].includes(key))) throw new Error();
    if (value.line !== undefined && (operation !== "grep" || !Number.isSafeInteger(value.line) || value.line < 0
      || !Number.isSafeInteger(value.size) || value.size < 0 || !Number.isFinite(value.mtimeMs))) throw new Error();
    return value;
  } catch { throw new FileError("invalid", "Invalid filesystem cursor or changed query; restart without cursor", args.path); }
}
function nextCursor(env: MountedExecutionEnv, operation: FileOperation, args: FileRequest, position: FilePosition | null) {
  if (position === null) return null;
  const cursor = JSON.stringify({ query: cursorQuery(env, operation, args), path: position.path, line: position.line, size: position.size, mtimeMs: position.mtimeMs });
  if (cursor.length > 65_536) throw new FileError("invalid", "Filesystem cursor exceeds its safety limit; narrow the search", args.path);
  return cursor;
}
const escaped = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
function expression(pattern: string, glob = false, ignoreCase = false) {
  if (!pattern || pattern.length > 1_024) throw new FileError("invalid", "Invalid search pattern");
  const source = glob ? pattern.split(/(\*\*\/|\*\*|\*|\?)/).map(part => {
    if (part === "**/") return "(?:.*/)?";
    if (part === "**") return ".*";
    if (part === "*") return "[^/]*";
    if (part === "?") return "[^/]";
    return escaped(part);
  }).join("") : pattern;
  const compiled = RE2JS.compile(glob ? `^${source}$` : source, ignoreCase ? RE2JS.CASE_INSENSITIVE : 0);
  if (compiled.programSize() > 4_096) throw new FileError("invalid", "Search pattern exceeds instruction limit");
  return compiled;
}
function requireExactEdits(text: string, edits: { oldText: string; newText: string }[]) {
  const normalized = text.replace(/\r\n/g, "\n");
  const ranges = edits.map(({ oldText }) => {
    const old = oldText.replace(/\r\n/g, "\n");
    const start = normalized.indexOf(old);
    if (!old || start < 0 || normalized.indexOf(old, start + 1) >= 0) throw new FileError("invalid", "Each oldText must be non-empty and match exactly once");
    return { start, end: start + old.length };
  }).sort((a, b) => a.start - b.start);
  if (ranges.some((range, index) => index > 0 && range.start < ranges[index - 1]!.end)) throw new FileError("invalid", "Edits must not overlap");
}
function excerpt(line: string, start = 0) {
  const characters = Array.from(line);
  if (characters.length <= 500) return line;
  const offset = Math.min(Math.max(0, Array.from(line.slice(0, start)).length - 200), characters.length - 498);
  return (offset ? "…" : "") + characters.slice(offset, offset + 498).join("") + "…";
}
function validateMutation(operation: FileOperation, args: FileRequest, path: string) {
  if (operation === "edit") {
    if (!args.edits!.length || args.edits!.length > 128) throw new FileError("invalid", "Use 1-128 targeted replacements");
    if (args.edits!.some(edit => !edit.oldText)) throw new FileError("invalid", "Each oldText must be non-empty and match exactly once");
  }
  if (operation === "write" && (args.content === undefined) === (args.base64 === undefined)) throw new FileError("invalid", "Pass exactly one of content or base64", path);
  if (operation === "write" && args.content !== undefined && encoder.encode(args.content).length > (path === "MEMORY.md" ? 512 : 200) * 1024) throw new FileError("invalid", "Text write exceeds size limit", path);
  if (immutableRoots.has(path.split("/").slice(0, 2).join("/"))) throw new FileError("permission_denied", "Bundled System skills are read-only; copy to a distinct name to customize", path);
}
export function resolveFileRequest(args: FileRequest, cwd: string): FileRequest {
  const roots = new Set(["app", "MEMORY.md", "skills", "repositories", "mounts", "files", "artifacts", "conversations", "history", "chats", "tmp"]);
  const resolve = (path: string) => {
    if (path.startsWith("/") || roots.has(path.split("/")[0]!)) {
      const parts = canonical(path).split("/");
      if (parts[0] === "files") parts[0] = "mounts";
      if (["history", "chats"].includes(parts[0]!)) {
        parts[0] = "conversations";
        if (parts[2] === "messages.jsonl") parts[2] = "turns.jsonl";
        if (parts[2] === "metadata") parts[2] = "conversation.json";
        if (parts[2] === "history") parts[2] = "turns.jsonl";
      }
      return parts.join("/");
    }
    if (path === "." || path === "") return canonical(cwd);
    return canonical([canonical(cwd), path].filter(Boolean).join("/"));
  };
  return { ...args, ...(args.from === undefined ? { path: resolve(args.path ?? ".") } : { from: resolve(args.from), to: resolve(args.to!) }) };
}
export function validateFileRequest(operation: FileOperation, args: FileRequest): FileRequest {
  const schema = filesystemContract[`ox.fs.${operation}`]?.inputSchema;
  if (!schema || !Value.Check(schema, args)) throw new FileError("invalid", `Invalid ox.fs.${operation} arguments`);
  const path = canonical(args.from ?? args.path ?? ".");
  const destination = args.to === undefined ? undefined : canonical(args.to);
  if (destination !== undefined && (!destination || destination.length > 4_096 || destination.split("/").length > 64)) throw new FileError("invalid", "Invalid transfer destination", destination);
  if (destination !== undefined) validateMutation(operation, args, destination);
  if (path.length > 4_096 || path.split("/").length > 64) throw new FileError("invalid", "Virtual path exceeds resource limits", path);
  if (operation === "read") {
    limit(args.offset, 1, Number.MAX_SAFE_INTEGER);
    limit(args.limit, 2_000, Number.MAX_SAFE_INTEGER);
  }
  if (mutations.has(operation)) validateMutation(operation, args, path);
  return { ...args, ...(args.from === undefined ? { path } : { from: path, to: destination }) };
}
function toolEnvironment(env: MountedExecutionEnv, args: FileRequest, onRead: (lines: number) => void) {
  let expected: string | undefined;
  return { ...env,
    openBinaryReader: async (...values: Parameters<typeof env.openBinaryReader>) => {
      const metadata = getOrThrow(await env.fileInfo(values[0], values[2]));
      if (metadata.size > 32 * 1024 * 1024) throw new FileError("invalid", "Source exceeds 32 MiB", args.path);
      const result = await env.openBinaryReader(...values);
      if (!result.ok) return result;
      const reader = result.value;
      const info = getOrThrow(await reader.info(values[2]));
      if (info.size > 32 * 1024 * 1024) {
        await reader.close(values[2]);
        throw new FileError("invalid", "Source exceeds 32 MiB", args.path);
      }
      return { ...result, value: { ...reader, scanLines: async (...scan: Parameters<typeof reader.scanLines>) => {
        const lines = await reader.scanLines(...scan);
        if (lines.ok) onRead(lines.value.newlines + 1);
        return lines;
      } } };
    },
    readTextFile: async (...values: Parameters<typeof env.readTextFile>) => {
      const text = await env.readTextFile(...values);
      if (text.ok && args.edits) {
        if (encoder.encode(text.value).length > (args.path === "MEMORY.md" ? 512 : 200) * 1024) throw new FileError("invalid", "Text edit exceeds size limit", args.path);
        requireExactEdits(text.value, args.edits);
        expected = text.value;
      }
      return text;
    },
    writeFile: async (...values: Parameters<typeof env.writeFile>) => {
      if (typeof values[1] !== "string" || encoder.encode(values[1]).length > (args.path === "MEMORY.md" ? 512 : 200) * 1024) throw new FileError("invalid", "Text write exceeds size limit", args.path);
      return expected === undefined ? env.writeFile(...values) : env.writeChecked(values[0], values[1], expected, values[2]);
    },
  };
}
async function executeFileTool(operation: "read" | "write" | "edit", args: FileRequest, env: MountedExecutionEnv, context: Context) {
  const api = new Proxy({ env }, { get: (target, name) => {
    if (name === "env") return target.env;
    if (operation === "read" && name === "agent") throw new FileError("not_supported", "Reading images is not supported; attach the file instead", args.path);
    throw new Error(`Filesystem tools cannot access invocation capability ${String(name)}`);
  } }) as unknown as ToolExecutionApi;
  if (operation === "read") return tools.read.execute({ path: args.path!, offset: args.offset, limit: args.limit }, api, context);
  if (operation === "write") return tools.write.execute({ path: args.path!, content: args.content! }, api, context);
  return tools.edit.execute({ path: args.path!, edits: args.edits! }, api, context);
}
function readPage(result: ToolExecutionResult, args: FileRequest, totalLines: number) {
  const text = result.output?.flatMap(block => block.type === "text" ? [block.text] : []).join("\n") ?? "";
  const clippedLine = result.diagnostics?.some(value => value.code === "truncated" && value.severity === "warn") ?? false;
  const next = (args.offset ?? 1) + text.split("\n").length;
  const truncated = clippedLine || next <= totalLines;
  const diagnostics = clippedLine ? [{ path: args.path!, message: "One line exceeds the 50 KiB read limit. Its remainder cannot be resumed with line offsets; use a narrower source or explicit conversion." }] : [];
  return { path: args.path, text, truncated, unsupported: null, nextOffset: truncated && !clippedLine ? next : null, diagnostics };
}
async function fileCandidates(env: MountedExecutionEnv, root: FileInfo, excluded: Set<string>, position: FilePosition | undefined, context: Context): Promise<Candidates> {
  const pending = [root];
  const paths: string[] = [];
  const diagnostics: Candidates["diagnostics"] = [];
  let visited = 0;
  let truncated = false;
  let lastPath = canonical(root.path);
  let nextPath: string | null = null;
  let deferred = false;
  const remaining = (info: FileInfo) => {
    if (!position || info === root) return true;
    const path = canonical(info.path);
    return comparePaths(path, position.path) > 0
      || info.kind === "directory" && (path === position.path || position.path.startsWith(path + "/"))
      || path === position.path && position.line !== undefined;
  };
  while (pending.length) {
    context.abortSignal?.throwIfAborted();
    const info = pending.pop()!;
    const path = canonical(info.path);
    if (excluded.has(path)) continue;
    if (!remaining(info)) continue;
    if (++visited > maximumEntries || paths.length >= maximumFiles) { truncated = true; nextPath = lastPath; break; }
    lastPath = path;
    if (info.kind === "directory") {
      const result = await env.listDir(path, context);
      context.abortSignal?.throwIfAborted();
      if (result.ok) {
        pending.push(...result.value.filter(remaining).sort((a, b) => comparePaths(canonical(b.path), canonical(a.path))));
        if (pending.length > maximumEntries) {
          pending.splice(0, pending.length - maximumEntries);
          deferred = true;
        }
      } else {
        if (info === root || !["not_found", "not_directory", "permission_denied", "unknown"].includes(result.error.code)) throw result.error;
        truncated = true;
        diagnostics.push({ path, message: result.error.message });
      }
    } else if (info.kind === "file") {
      if (position && path === position.path && position.line === undefined) continue;
      paths.push(path);
    }
  }
  if (deferred) { truncated = true; nextPath ??= lastPath; }
  return { paths, truncated, diagnostics, nextPath };
}
async function searchFile(env: MountedExecutionEnv, path: string, remainingBytes: number, position: FilePosition | undefined, context: Context) {
  const info = getOrThrow(await env.fileInfo(path, context));
  if (position?.path === path && position.line !== undefined && (position.size !== info.size || position.mtimeMs !== (info.mtimeMs ?? 0))) {
    throw new FileError("invalid", "Search file changed; restart without cursor", path);
  }
  if (info.size > remainingBytes) return { kind: "limited" as const };
  const result = await env.readTextFile(path, context);
  if (!result.ok) {
    if (result.error.code !== "not_supported") throw result.error;
    return { kind: "unsupported" as const };
  }
  const bytes = encoder.encode(result.value).length;
  if (bytes > remainingBytes) return { kind: "limited" as const };
  return { kind: "text" as const, text: result.value, bytes, size: info.size, mtimeMs: info.mtimeMs ?? 0 };
}
function searchLines(path: string, text: string, pattern: RE2JS, contextLines: number, remainingMatches: number, context: Context, startLine = 0) {
  const lines = text.split("\n");
  const matches: SearchMatch[] = [];
  for (let index = startLine; index < lines.length; index++) {
    context.abortSignal?.throwIfAborted();
    const found = pattern.matcher(lines[index]!);
    if (!found.find()) continue;
    matches.push({ path, line: index + 1, text: excerpt(lines[index]!, found.start()),
      before: lines.slice(Math.max(0, index - contextLines), index).map(line => excerpt(line)),
      after: lines.slice(index + 1, index + 1 + contextLines).map(line => excerpt(line)) });
    if (matches.length >= remainingMatches) break;
  }
  return matches;
}
const relativePath = (base: string, path: string) => base && path !== base ? path.slice(base.length + 1) : path;
const searchBudget = (base: string) => base === "conversations" || base.startsWith("conversations/") ? 16 * 1024 * 1024 : 2 * 1024 * 1024;
async function grepFiles(env: MountedExecutionEnv, candidates: Candidates, args: FileRequest, match: RE2JS, position: FilePosition | undefined, context: Context) {
  const base = args.path!;
  const options = args.options ?? {};
  const count = options.limit ?? 100;
  const filter = options.glob ? expression(options.glob, true) : undefined;
  const budget = base === "app/logs.jsonl" && env.mounts.some(mount => mount.path === "app") ? 32 * 1024 * 1024 : searchBudget(base);
  const contextLines = options.contextLines ?? 0;
  const matches: SearchMatch[] = [];
  let scannedFiles = 0;
  let skippedFiles = 0;
  let bytes = 0;
  let truncated = candidates.truncated;
  let resume: FilePosition | null = position ?? null;
  let continuation: FilePosition | null = candidates.nextPath === null ? null : { path: candidates.nextPath };
  for (const path of candidates.paths) {
    context.abortSignal?.throwIfAborted();
    if (filter && !filter.test(relativePath(base, path))) { resume = { path }; continue; }
    const file = await searchFile(env, path, budget - bytes, position, context);
    if (file.kind === "limited") {
      truncated = true;
      if (bytes > 0) { continuation = resume; break; }
      candidates.diagnostics.push({ path, message: "File exceeds the per-page search byte budget; narrow or convert this source." });
      resume = { path };
      continue;
    }
    if (file.kind === "unsupported") { skippedFiles++; resume = { path }; continue; }
    scannedFiles++;
    bytes += file.bytes;
    const remaining = count - matches.length;
    const found = searchLines(path, file.text, match, contextLines, remaining + 1, context, position?.path === path ? position.line ?? 0 : 0);
    matches.push(...found.slice(0, remaining));
    if (found.length > remaining) {
      truncated = true;
      continuation = { path, line: found[remaining]!.line - 1, size: file.size, mtimeMs: file.mtimeMs };
      break;
    }
    resume = { path };
  }
  return { matches, scannedFiles, skippedFiles, truncated, nextCursor: nextCursor(env, "grep", args, continuation), diagnostics: candidates.diagnostics };
}

export class AgentFileSystem {
  private mutations = new Map<string, Promise<unknown>>();
  private operations = new Set<Promise<unknown>>();
  private closed = false;

  async close() {
    this.closed = true;
    await Promise.allSettled([...this.operations]);
  }

  async invoke(env: MountedExecutionEnv, operation: FileOperation, args: FileRequest, context: Context): Promise<unknown> {
    if (this.closed) throw new FileError("invalid", "Filesystem scope is closed");
    if (this.operations.size >= 128) throw new FileError("invalid", "Too many concurrent filesystem operations");
    const pending = this.invokeScoped(env, operation, args, context);
    this.operations.add(pending);
    try { return await pending; } finally { this.operations.delete(pending); }
  }

  private async invokeScoped(env: MountedExecutionEnv, operation: FileOperation, args: FileRequest, context: Context): Promise<unknown> {
    context.abortSignal?.throwIfAborted();
    args = validateFileRequest(operation, args);
    const path = args.from ?? args.path!;
    if (mutations.has(operation)) {
      if (operation !== "copy") env.assertWritable(path);
      if (args.to !== undefined) env.assertWritable(args.to);
      const key = env.id;
      const previous = this.mutations.get(key) ?? Promise.resolve();
      const next = previous.catch(() => {}).then(() => this.perform(env, operation, args, context));
      this.mutations.set(key, next);
      try { return await next; } finally { if (this.mutations.get(key) === next) this.mutations.delete(key); }
    }
    return this.perform(env, operation, args, context);
  }

  private async perform(env: MountedExecutionEnv, operation: FileOperation, args: FileRequest, context: Context): Promise<unknown> {
    context.abortSignal?.throwIfAborted();
    const path = args.from ?? args.path!;
    if (operation === "stat") return item(getOrThrow(await env.fileInfo(path, context)));
    if (operation === "mkdir") {
      getOrThrow(await env.createDir(path, { recursive: args.recursive ?? false }, context));
      return item(getOrThrow(await env.fileInfo(path, context)));
    }
    if (operation === "move" || operation === "copy") {
      getOrThrow(await env.transfer(path, args.to!, operation === "copy", context));
      return item(getOrThrow(await env.fileInfo(args.to!, context)));
    }
    if (operation === "list") {
      const position = cursorPosition(env, operation, args);
      const entries = getOrThrow(await env.listDir(path, context))
        .filter(entry => !position || comparePaths(canonical(entry.path), position.path) > 0)
        .sort((a, b) => comparePaths(canonical(a.path), canonical(b.path)));
      const count = args.options?.limit ?? 50;
      const page = entries.slice(0, count);
      return { items: page.map(item), truncated: entries.length > count,
        nextCursor: nextCursor(env, operation, args, entries.length > count ? { path: canonical(page.at(-1)!.path) } : null) };
    }
    if (operation === "rm") {
      if ((getOrThrow(await env.fileInfo(path, context))).kind === "directory") {
        getOrThrow(await env.removeDirectory(path, args.recursive ?? false, context));
      } else {
        getOrThrow(await env.remove(path, undefined, context));
      }
      return { path, deleted: true };
    }
    if (operation === "glob" || operation === "grep") return this.search(env, operation, args, context);
    if (operation === "write" && args.base64 !== undefined) {
      let bytes: Uint8Array;
      try { bytes = decodeBase64(args.base64); } catch { throw new FileError("invalid", "base64 must be standard padded Base64 of at most 32 MiB", path); }
      getOrThrow(await env.writeFile(path, bytes, context));
      return item(getOrThrow(await env.fileInfo(path, context)));
    }
    let totalLines = 0;
    const toolEnv = toolEnvironment(env, args, value => { totalLines = value; });
    const result = await executeFileTool(operation, args, toolEnv, context);
    if (result.isError) throw new FileError("not_supported", result.diagnostics?.map(value => value.message).join("\n") ?? "File operation failed", path);
    if (operation === "read") return readPage(result, args, totalLines);
    return { ...item(getOrThrow(await env.fileInfo(path, context))), ...(operation === "edit" && typeof result.details === "object" ? result.details : {}) };
  }

  private async search(env: MountedExecutionEnv, operation: "glob" | "grep", args: FileRequest, context: Context) {
    const base = args.path!;
    const options = args.options ?? {};
    const literal = operation === "grep" && options.literal;
    const match = expression(literal ? escaped(args.pattern!) : args.pattern!, operation === "glob", options.ignoreCase);
    const position = cursorPosition(env, operation, args);
    const root = getOrThrow(await env.fileInfo(base, context));
    if (position?.line !== undefined) getOrThrow(await env.fileInfo(position.path, context));
    if (operation === "glob" && root.kind !== "directory") throw new FileError("not_directory", "Not a directory", base);
    const excluded = base ? [] : ["mounts", "files"];
    const candidates = await fileCandidates(env, root, new Set(excluded), position, context);
    if (operation === "grep" && base !== "conversations" && !base.startsWith("conversations/")) candidates.paths = candidates.paths.filter(path => !/^conversations\/[^/]+\/(conversation\.json|turns\.jsonl|metadata|history)$/.test(path));
    if (operation === "grep" && base !== "app/logs.jsonl" && env.mounts.some(mount => mount.path === "app") && candidates.paths.includes("app/logs.jsonl")) {
      candidates.paths = candidates.paths.filter(path => path !== "app/logs.jsonl");
      candidates.diagnostics.push({ path: "app/logs.jsonl", message: "App-wide logs are excluded from directory searches; read or search this path explicitly with approval." });
    }
    if (operation === "grep") return grepFiles(env, candidates, args, match, position, context);
    const paths = candidates.paths.filter(path => match.test(relativePath(base, path)));
    const count = options.limit ?? 100;
    const continuation = paths.length > count ? paths[count - 1]! : candidates.nextPath;
    return { paths: paths.slice(0, count), truncated: candidates.truncated || paths.length > count,
      nextCursor: nextCursor(env, operation, args, continuation === null ? null : { path: continuation }), diagnostics: candidates.diagnostics };
  }
}

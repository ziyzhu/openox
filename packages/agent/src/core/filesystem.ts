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
export type FileOperation = "list" | "read" | "write" | "edit" | "rm" | "mkdir" | "move" | "copy" | "glob" | "grep";
export interface FileRequest {
  path?: string; from?: string; to?: string; recursive?: boolean; purpose?: string; offset?: number; limit?: number; content?: string; base64?: string;
  edits?: { oldText: string; newText: string }[]; pattern?: string;
  options?: { limit?: number; glob?: string; ignoreCase?: boolean; literal?: boolean; contextLines?: number };
}
type SearchMatch = { path: string; line: number; text: string; before: string[]; after: string[] };
type Candidates = { paths: string[]; truncated: boolean; diagnostics: { severity: string; code: string; message: string }[] };
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
  if (operation === "write" && args.content !== undefined && encoder.encode(args.content).length > 200 * 1024) throw new FileError("invalid", "Text write exceeds 200 KiB", path);
  if (immutableRoots.has(path.split("/").slice(0, 2).join("/"))) throw new FileError("permission_denied", "Bundled System skills are read-only; copy to a distinct name to customize", path);
}
export function resolveFileRequest(args: FileRequest, cwd: string): FileRequest {
  const roots = new Set(["MEMORY.md", "SOUL.md", "skills", "services", "files", "artifacts", "conversations", "history", "tmp"]);
  const resolve = (path: string) => {
    if (path.startsWith("/") || roots.has(path.split("/")[0]!)) {
      const parts = canonical(path).split("/");
      const uuid = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(parts[1] ?? "");
      if (parts[0] === "history" || (parts[0] === "conversations" && uuid)) {
        parts[0] = uuid ? "history" : "conversations";
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
        if (encoder.encode(text.value).length > 200 * 1024) throw new FileError("invalid", "Text edit exceeds 200 KiB", args.path);
        requireExactEdits(text.value, args.edits);
        expected = text.value;
      }
      return text;
    },
    writeFile: async (...values: Parameters<typeof env.writeFile>) => {
      if (typeof values[1] !== "string" || encoder.encode(values[1]).length > 200 * 1024) throw new FileError("invalid", "Text write exceeds 200 KiB", args.path);
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
  const diagnostics = (result.diagnostics ?? []).map(value => clippedLine && value.code === "truncated"
    ? { ...value, message: "One line exceeds the 50 KiB read limit. Its remainder cannot be resumed with line offsets; use a narrower source or explicit conversion." } : value);
  return { path: args.path, text, truncated, unsupported: null, nextOffset: truncated && !clippedLine ? next : null, diagnostics };
}
async function fileCandidates(env: MountedExecutionEnv, root: FileInfo, excluded: Set<string>, context: Context): Promise<Candidates> {
  const pending = [root];
  const paths: string[] = [];
  const diagnostics: Candidates["diagnostics"] = [];
  let visited = 0;
  let truncated = false;
  while (pending.length) {
    context.abortSignal?.throwIfAborted();
    const info = pending.shift()!;
    if (++visited > maximumEntries || paths.length >= maximumFiles) { truncated = true; break; }
    const path = canonical(info.path);
    if (excluded.has(path)) continue;
    if (info.kind === "directory") {
      const result = await env.listDir(path, context);
      context.abortSignal?.throwIfAborted();
      if (result.ok) pending.push(...result.value);
      else {
        if (info === root || !["not_found", "not_directory", "permission_denied", "unknown"].includes(result.error.code)) throw result.error;
        truncated = true;
        diagnostics.push({ severity: "warn", code: result.error.code, message: `Could not search ${path}: ${result.error.message}` });
      }
    } else if (info.kind === "file") paths.push(path);
  }
  return { paths: paths.sort(), truncated, diagnostics };
}
async function searchFile(env: MountedExecutionEnv, path: string, remainingBytes: number, context: Context) {
  const info = getOrThrow(await env.fileInfo(path, context));
  if (info.size > remainingBytes) return { kind: "limited" as const };
  const result = await env.readTextFile(path, context);
  if (!result.ok) {
    if (result.error.code !== "not_supported") throw result.error;
    return { kind: "unsupported" as const };
  }
  const bytes = encoder.encode(result.value).length;
  if (bytes > remainingBytes) return { kind: "limited" as const };
  return { kind: "text" as const, text: result.value, bytes };
}
function searchLines(path: string, text: string, pattern: RE2JS, contextLines: number, remainingMatches: number, context: Context) {
  const lines = text.split("\n");
  const matches: SearchMatch[] = [];
  for (let index = 0; index < lines.length; index++) {
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
async function grepFiles(env: MountedExecutionEnv, candidates: Candidates, args: FileRequest, match: RE2JS, context: Context) {
  const base = args.path!;
  const options = args.options ?? {};
  const count = options.limit ?? 100;
  const filter = options.glob ? expression(options.glob, true) : undefined;
  const budget = searchBudget(base);
  const contextLines = options.contextLines ?? 0;
  const matches: SearchMatch[] = [];
  let scannedFiles = 0;
  let skippedFiles = 0;
  let bytes = 0;
  let truncated = candidates.truncated;
  for (const path of candidates.paths) {
    context.abortSignal?.throwIfAborted();
    if (filter && !filter.test(relativePath(base, path))) continue;
    const file = await searchFile(env, path, budget - bytes, context);
    if (file.kind === "limited") { truncated = true; break; }
    if (file.kind === "unsupported") { skippedFiles++; continue; }
    scannedFiles++;
    bytes += file.bytes;
    matches.push(...searchLines(path, file.text, match, contextLines, count - matches.length, context));
    if (matches.length >= count) { truncated = true; break; }
  }
  return { matches, scannedFiles, skippedFiles, truncated, diagnostics: candidates.diagnostics };
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
    if (operation === "mkdir") {
      getOrThrow(await env.createDir(path, { recursive: args.recursive ?? false }, context));
      return item(getOrThrow(await env.fileInfo(path, context)));
    }
    if (operation === "move" || operation === "copy") {
      getOrThrow(await env.transfer(path, args.to!, operation === "copy", context));
      return item(getOrThrow(await env.fileInfo(args.to!, context)));
    }
    if (operation === "list") {
      const entries = getOrThrow(await env.listDir(path, context));
      const count = args.options?.limit ?? 50;
      return { items: entries.slice(0, count).map(item), truncated: entries.length > count };
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
    const root = getOrThrow(await env.fileInfo(base, context));
    if (operation === "glob" && root.kind !== "directory") throw new FileError("not_directory", "Not a directory", base);
    const excluded = base ? [] : ["files"];
    const candidates = await fileCandidates(env, root, new Set(excluded), context);
    if (operation === "grep" && base !== "conversations" && !base.startsWith("conversations/")) candidates.paths = candidates.paths.filter(path => !/^conversations\/[^/]+\/(conversation\.json|turns\.jsonl|metadata|history)$/.test(path));
    if (operation === "grep") return grepFiles(env, candidates, args, match, context);
    const paths = candidates.paths.filter(path => match.test(relativePath(base, path)));
    const count = options.limit ?? 100;
    return { paths: paths.slice(0, count), truncated: candidates.truncated || paths.length > count, diagnostics: candidates.diagnostics };
  }
}

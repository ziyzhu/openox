import { createReadTool, createWriteTool, createEditTool } from "@earendil-works/pi-durable/tools";
import { guidanceTexts } from "./guidance-texts";

const string = (description: string) => ({ type: "string", description });
const integer = (description: string, minimum: number, maximum: number) => ({ type: "integer", description, minimum, maximum });
const boolean = (description: string) => ({ type: "boolean", description });
const object = (properties: Record<string, unknown>, required: string[] = []) => ({ type: "object", properties, required, additionalProperties: false });
const array = (items: unknown) => ({ type: "array", items });
const path = string("Virtual filesystem path, relative or absolute.");
const purpose = { ...string("Short (<10 words) description shown to the user as the step label."), minLength: 1, maxLength: 80 };
const input = (properties: Record<string, unknown>, required: string[] = []) => object({ purpose, ...properties }, ["purpose", ...required]);
const itemProperties = { path, name: string("Final component."), type: { type: "string", enum: ["file", "directory"] }, size: { type: ["integer", "null"] },
  mtimeMs: { type: ["integer", "null"], description: "Last modification time in Unix milliseconds, or null when unknown." },
  cloud: { type: ["string", "null"], enum: ["current", "outdated", "cloudOnly", "downloading", "uploading", "conflict", "error", null],
    description: "iCloud sync state for a file in a selected iCloud folder, or null for other files." } };
const itemRequired = ["path", "name", "type", "size", "mtimeMs", "cloud"];
const item = object(itemProperties, itemRequired);
const nullableString = { type: ["string", "null"] };
const cursor = { ...string("Continuation from the previous page of this same operation, path, query, and options."), minLength: 1, maxLength: 65_536 };
const diagnostics = array(object({ path, message: string("Why this path could not be read completely or searched.") }, ["path", "message"]));
const tools = { read: createReadTool(), write: createWriteTool(), edit: createEditTool() };
export const filesystemInputs = Object.fromEntries(Object.entries(tools).map(([name, tool]) => [name, {
  ...tool.parameters, ...input(tool.parameters.properties as Record<string, unknown>, tool.parameters.required as string[]),
}]));
const schemas = {
  stat: { inputSchema: input({ path }, ["path"]), outputSchema: item },
  list: { inputSchema: input({ path, cursor, options: object({ limit: integer("Maximum entries.", 1, 100) }) }),
    outputSchema: object({ items: array(item), truncated: boolean("More entries remain."), nextCursor: nullableString }, ["items", "truncated", "nextCursor"]) },
  read: { inputSchema: { ...filesystemInputs.read, properties: { ...filesystemInputs.read.properties,
    offset: integer("Line number to start reading from (1-indexed).", 1, Number.MAX_SAFE_INTEGER),
    limit: integer("Maximum number of lines to read.", 1, Number.MAX_SAFE_INTEGER),
  } },
    outputSchema: object({ path, text: nullableString, truncated: boolean("More text remains."), unsupported: nullableString,
      nextOffset: { type: ["integer", "null"] }, diagnostics },
    ["path", "text", "truncated", "unsupported", "nextOffset", "diagnostics"]) },
  write: { inputSchema: { ...filesystemInputs.write,
    properties: { ...filesystemInputs.write.properties, base64: string("Standard Base64 bytes for a binary file, up to 32 MiB decoded; use instead of content.") },
    required: ["purpose", "path"] }, outputSchema: item },
  edit: { inputSchema: { ...filesystemInputs.edit, properties: { ...filesystemInputs.edit.properties,
    edits: { type: "array", minItems: 1, maxItems: 128, items: object({ oldText: { ...string("Unique, non-empty text from the original file."), minLength: 1 }, newText: string("Replacement text.") }, ["oldText", "newText"]) },
  } },
    outputSchema: object({ ...itemProperties, patch: string("Unified patch."), firstChangedLine: integer("First changed line.", 1, Number.MAX_SAFE_INTEGER) },
      [...itemRequired, "patch"]) },
  mkdir: { inputSchema: input({ path, recursive: boolean("Create missing parents; accept an existing directory.") }, ["path"]), outputSchema: item },
  rm: { inputSchema: input({ path, recursive: boolean("Explicitly trash a nonempty directory and all its contents, including dotfiles.") }, ["path"]), outputSchema: object({ path, deleted: boolean("Moved to native trash.") }, ["path", "deleted"]) },
  move: { inputSchema: input({ from: path, to: path }, ["from", "to"]), outputSchema: item },
  copy: { inputSchema: input({ from: path, to: path }, ["from", "to"]), outputSchema: item },
  glob: { inputSchema: input({ path, cursor, pattern: string("Glob supporting *, **, and ?."), options: object({ limit: integer("Maximum paths.", 1, 1_000) }) }, ["pattern"]),
    outputSchema: object({ paths: array(path), diagnostics, truncated: boolean("Search is incomplete because a limit was reached or a directory was unavailable."), nextCursor: nullableString }, ["paths", "truncated", "nextCursor"]) },
  grep: { inputSchema: input({ path, cursor, pattern: string("Regular expression or literal text."), options: object({
    limit: integer("Maximum matches.", 1, 200), glob: string("Path glob."), ignoreCase: boolean("Ignore case."), literal: boolean("Literal search."), contextLines: integer("Context lines.", 0, 5),
  }) }, ["pattern"]), outputSchema: object({ matches: array(object({ path, line: integer("Line number.", 1, Number.MAX_SAFE_INTEGER), text: string("Matched excerpt."),
    before: array(string("Context.")), after: array(string("Context.")) }, ["path", "line", "text", "before", "after"])),
    scannedFiles: integer("Scanned files.", 0, 1_000), skippedFiles: integer("Unsupported files.", 0, 1_000), diagnostics, truncated: boolean("Search is incomplete because a limit was reached or a directory was unavailable."), nextCursor: nullableString },
    ["matches", "scannedFiles", "skippedFiles", "truncated", "nextCursor"]) },
  attach: { inputSchema: input({ path: string("File path or public HTTP(S) URL.") }, ["path"]),
    outputSchema: object({ filename: string("Filename."), contentType: string("MIME type."), bytes: integer("Attachment bytes.", 1, 20 * 1024 * 1024), kind: { type: "string", enum: ["image", "pdf", "text", "file"] } },
      ["filename", "contentType", "bytes", "kind"]) },
};
export const filesystemContract = Object.fromEntries(Object.entries(schemas).map(([name, schema]) => [`ox.fs.${name}`, {
  description: guidanceTexts[`ox.fs.${name}`], ...schema,
}]));

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
const cursor = { ...string("Continuation from the previous page of this same operation, path, query, and options."), minLength: 1, maxLength: 65_536 };
const image = object({ type: { const: "image", type: "string" }, data: string("Base64 image data."), mimeType: string("Image MIME type."), note: string("Image information.") },
  ["type", "data", "mimeType", "note"]);
const tools = { read: createReadTool(), write: createWriteTool(), edit: createEditTool() };
export const filesystemInputs = Object.fromEntries(Object.entries(tools).map(([name, tool]) => [name, {
  ...tool.parameters, ...input(tool.parameters.properties as Record<string, unknown>, tool.parameters.required as string[]),
}]));
const schemas = {
  stat: { inputSchema: input({ path }, ["path"]), outputSchema: item },
  ls: { inputSchema: input({ path, cursor, limit: integer("Maximum entries.", 1, 100) }),
    outputSchema: string("Directory listing and any continuation hint.") },
  read: { inputSchema: { ...filesystemInputs.read, properties: { ...filesystemInputs.read.properties,
    byteOffset: integer("Zero-based UTF-8 byte offset for an 8 KiB text page; use instead of offset and limit.", 0, Number.MAX_SAFE_INTEGER),
    offset: integer("Line number to start reading from (1-indexed).", 1, Number.MAX_SAFE_INTEGER),
    limit: integer("Maximum number of lines to read.", 1, Number.MAX_SAFE_INTEGER),
  } },
    outputSchema: { anyOf: [string("File text and any continuation or unsupported-format hint."), image] } },
  write: { inputSchema: { ...filesystemInputs.write,
    properties: { ...filesystemInputs.write.properties, base64: string("Standard Base64 bytes for a binary file, up to 32 MiB decoded; use instead of content.") },
    required: ["purpose", "path"] }, outputSchema: string("Write confirmation.") },
  edit: { inputSchema: { ...filesystemInputs.edit, properties: { ...filesystemInputs.edit.properties,
    edits: { type: "array", minItems: 1, maxItems: 128, items: object({ oldText: { ...string("Unique, non-empty text from the original file."), minLength: 1 }, newText: string("Replacement text.") }, ["oldText", "newText"]) },
  } },
    outputSchema: string("Edit confirmation.") },
  mkdir: { inputSchema: input({ path, recursive: boolean("Create missing parents; accept an existing directory.") }, ["path"]), outputSchema: item },
  rm: { inputSchema: input({ path, recursive: boolean("Explicitly trash a nonempty directory and all its contents, including dotfiles.") }, ["path"]), outputSchema: object({ path, deleted: boolean("Moved to native trash.") }, ["path", "deleted"]) },
  move: { inputSchema: input({ from: path, to: path }, ["from", "to"]), outputSchema: item },
  copy: { inputSchema: input({ from: path, to: path }, ["from", "to"]), outputSchema: item },
  find: { inputSchema: input({ path, cursor, pattern: string("Glob supporting *, **, and ?."), limit: integer("Maximum paths.", 1, 1_000) }, ["pattern"]),
    outputSchema: string("Matching paths and any continuation or diagnostic hints.") },
  grep: { inputSchema: input({ path, cursor, pattern: string("Regular expression or literal text."),
    glob: string("Path glob."), ignoreCase: boolean("Ignore case."), literal: boolean("Literal search."), context: integer("Context lines.", 0, 5), limit: integer("Maximum matches.", 1, 200),
  }, ["pattern"]), outputSchema: string("Matching lines with paths and line numbers, plus any context, continuation, or diagnostic hints.") },
  attach: { inputSchema: input({ path: string("File path or public HTTP(S) URL.") }, ["path"]),
    outputSchema: object({ filename: string("Filename."), contentType: string("MIME type."), bytes: integer("Attachment bytes.", 1, 20 * 1024 * 1024), kind: { type: "string", enum: ["image", "pdf", "text", "file"] } },
      ["filename", "contentType", "bytes", "kind"]) },
};
export const filesystemContract = Object.fromEntries(Object.entries(schemas).map(([name, schema]) => [`ox.fs.${name}`, {
  description: guidanceTexts[`ox.fs.${name}`], ...schema,
}]));

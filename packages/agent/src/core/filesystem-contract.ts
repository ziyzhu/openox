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
const itemProperties = { path, name: string("Final component."), type: { type: "string", enum: ["file", "directory"] }, size: { type: ["integer", "null"] } };
const item = object(itemProperties, ["path", "name", "type", "size"]);
const nullableString = { type: ["string", "null"] };
const tools = { read: createReadTool(), write: createWriteTool(), edit: createEditTool() };
export const filesystemInputs = Object.fromEntries(Object.entries(tools).map(([name, tool]) => [name, {
  ...tool.parameters, ...input(tool.parameters.properties, tool.parameters.required),
}]));
const schemas = {
  list: { inputSchema: input({ path, options: object({ limit: integer("Maximum entries.", 1, 100) }) }),
    outputSchema: object({ items: array(item), truncated: boolean("More entries remain.") }, ["items", "truncated"]) },
  read: { inputSchema: filesystemInputs.read,
    outputSchema: object({ path, text: nullableString, truncated: boolean("More text remains."), unsupported: nullableString,
      nextOffset: { type: ["integer", "null"] }, diagnostics: array(object({ severity: string("Severity."), code: string("Diagnostic code."), message: string("Diagnostic.") }, ["severity", "message"])) },
    ["path", "text", "truncated", "unsupported", "nextOffset", "diagnostics"]) },
  write: { inputSchema: filesystemInputs.write, outputSchema: item },
  edit: { inputSchema: filesystemInputs.edit,
    outputSchema: object({ ...itemProperties, diff: string("Changed lines."), patch: string("Unified patch."), firstChangedLine: integer("First changed line.", 1, Number.MAX_SAFE_INTEGER) },
      ["path", "name", "type", "size", "diff", "patch"]) },
  delete: { inputSchema: input({ path }, ["path"]), outputSchema: object({ path, deleted: boolean("Deleted.") }, ["path", "deleted"]) },
  glob: { inputSchema: input({ path, pattern: string("Glob supporting *, **, and ?."), options: object({ limit: integer("Maximum paths.", 1, 1_000) }) }, ["pattern"]),
    outputSchema: object({ paths: array(path), truncated: boolean("More paths remain.") }, ["paths", "truncated"]) },
  grep: { inputSchema: input({ path, pattern: string("Regular expression or literal text."), options: object({
    limit: integer("Maximum matches.", 1, 200), glob: string("Path glob."), ignoreCase: boolean("Ignore case."), literal: boolean("Literal search."), contextLines: integer("Context lines.", 0, 5),
  }) }, ["pattern"]), outputSchema: object({ matches: array(object({ path, line: integer("Line number.", 1, Number.MAX_SAFE_INTEGER), text: string("Matched excerpt."),
    before: array(string("Context.")), after: array(string("Context.")) }, ["path", "line", "text", "before", "after"])),
    scannedFiles: integer("Scanned files.", 0, 1_000), skippedFiles: integer("Unsupported files.", 0, 1_000), truncated: boolean("Search limit reached.") },
    ["matches", "scannedFiles", "skippedFiles", "truncated"]) },
  attach: { inputSchema: input({ path: string("File path or public HTTP(S) URL.") }, ["path"]),
    outputSchema: object({ filename: string("Filename."), contentType: string("MIME type."), bytes: integer("Attachment bytes.", 1, 20 * 1024 * 1024), kind: { type: "string", enum: ["image", "pdf", "text", "file"] } },
      ["filename", "contentType", "bytes", "kind"]) },
};
export const filesystemContract = Object.fromEntries(Object.entries(schemas).map(([name, schema]) => [`ox.fs.${name}`, {
  description: guidanceTexts[`ox.fs.${name}`], ...schema,
}]));

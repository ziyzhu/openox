import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { TSchema } from "@sinclair/typebox";
import { VMControlRequestSchema, VMControlResponseSchema } from "../protocol/host/schema.ts";
import { ChatMetadataSchema, ProfileConfigSchema } from "../protocol/profile/schema.ts";
import { JSONValueSchema } from "../protocol/schema.ts";
import { RepositoryPackageSchema, ServiceManifestSchema } from "../protocol/services/schema.ts";
import { ROOT } from "./lib.ts";

const check = process.argv.includes("--check");
const schemas: Array<{ path: string; schema: TSchema; id: string; jsonValue?: boolean }> = [
  {
    path: "protocol/host/vm-control-request.schema.json",
    schema: VMControlRequestSchema,
    id: "https://openox.ai/schemas/vm-control-request-v1.json",
    jsonValue: true,
  },
  {
    path: "protocol/host/vm-control-response.schema.json",
    schema: VMControlResponseSchema,
    id: "https://openox.ai/schemas/vm-control-response-v1.json",
    jsonValue: true,
  },
  {
    path: "protocol/profile/profile.schema.json",
    schema: ProfileConfigSchema,
    id: "https://openox.ai/schemas/profile-config-v1.json",
  },
  {
    path: "protocol/profile/chat.schema.json",
    schema: ChatMetadataSchema,
    id: "https://openox.ai/schemas/chat-metadata-v1.json",
  },
  {
    path: "protocol/services/repository.schema.json",
    schema: RepositoryPackageSchema,
    id: "https://openox.ai/schemas/repository-v1.json",
  },
  {
    path: "protocol/services/service.schema.json",
    schema: ServiceManifestSchema,
    id: "https://openox.ai/schemas/service-v1.json",
  },
];

let mismatches = 0;
for (const entry of schemas) {
  const path = join(ROOT, entry.path);
  const structural = entry.jsonValue ? extractJSONValue(entry.schema) : entry.schema;
  const document = `${JSON.stringify({
    $schema: "https://json-schema.org/draft/2020-12/schema",
    ...structural,
    $id: entry.id,
  }, null, 2)}\n`;
  validateSchemaDocument(JSON.parse(document), entry.path);
  if (check) {
    const current = await readFile(path, "utf8").catch(() => "");
    if (current !== document) {
      console.error(`STALE ${entry.path}`);
      mismatches += 1;
    }
  } else {
    await writeFile(path, document);
    console.log(`WROTE ${entry.path}`);
  }
}

if (mismatches > 0) {
  console.error("Run bun run build:protocol");
  process.exit(1);
}

if (check) console.log(`PASS protocol schemas ${schemas.length} files`);

function extractJSONValue(schema: TSchema): TSchema {
  const definition = rewriteJSONValue(JSON.parse(JSON.stringify(JSONValueSchema)), true) as Record<string, unknown>;
  const root = rewriteJSONValue(JSON.parse(JSON.stringify(schema)), false) as Record<string, unknown>;
  return { ...root, $defs: { JSONValue: definition } } as unknown as TSchema;
}

function rewriteJSONValue(value: unknown, definition: boolean): unknown {
  if (Array.isArray(value)) return value.map(item => rewriteJSONValue(item, definition));
  if (!value || typeof value !== "object") return value;
  const object = value as Record<string, unknown>;
  if (!definition && object.$id === "JSONValue") return { $ref: "#/$defs/JSONValue" };
  const rewritten: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(object)) {
    if (key === "$id" && item === "JSONValue") continue;
    rewritten[key] = key === "$ref" && item === "JSONValue"
      ? "#/$defs/JSONValue"
      : rewriteJSONValue(item, definition);
  }
  return rewritten;
}

function validateSchemaDocument(root: unknown, path: string): void {
  const ids = new Set<string>();
  const visit = (value: unknown) => {
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (!value || typeof value !== "object") return;
    const object = value as Record<string, unknown>;
    if (typeof object.$id === "string") {
      if (ids.has(object.$id)) throw new Error(`${path}: duplicate $id ${object.$id}`);
      ids.add(object.$id);
    }
    if (typeof object.$ref === "string") {
      if (!object.$ref.startsWith("#/")) throw new Error(`${path}: non-local $ref ${object.$ref}`);
      if (resolvePointer(root, object.$ref) === undefined) throw new Error(`${path}: unresolved $ref ${object.$ref}`);
    }
    Object.values(object).forEach(visit);
  };
  visit(root);
}

function resolvePointer(root: unknown, reference: string): unknown {
  let value = root;
  for (const raw of reference.slice(2).split("/")) {
    if (!value || typeof value !== "object") return undefined;
    const key = raw.replace(/~1/g, "/").replace(/~0/g, "~");
    value = (value as Record<string, unknown>)[key];
  }
  return value;
}

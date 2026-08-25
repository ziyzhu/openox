import { existsSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { Type, type Static } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";
import { validateJSONSchemaProfile } from "@openox/service-sdk/manifest";

const ID_RE = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/;
const IOS_ID_RE = /^ios:[a-z0-9]+(?:[.-][a-z0-9]+)*$/;
const IOS_ACTION_ID_RE = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
const IOS_VERSION_RE = /^(?:[1-9][0-9]*)(?:\.[0-9]+){0,2}$/;

const JSONSchemaSchema = Type.Object({}, { additionalProperties: true });

const IOSActionSchema = Type.Object({
  id: Type.String({ pattern: IOS_ACTION_ID_RE.source }),
  label: Type.String({ minLength: 1 }),
  description: Type.Optional(Type.String()),
  inputSchema: JSONSchemaSchema,
  outputSchema: Type.Union([JSONSchemaSchema, Type.Null()]),
  requireApproval: Type.Boolean(),
  requireAuth: Type.Literal(false),
}, { additionalProperties: false });

const IOSLocaleSchema = Type.Object({
  name: Type.Optional(Type.String({ minLength: 1 })),
  description: Type.Optional(Type.String()),
  actions: Type.Optional(Type.Record(Type.String(), Type.Object({
    label: Type.Optional(Type.String({ minLength: 1 })),
    description: Type.Optional(Type.String()),
  }, { additionalProperties: false }))),
}, { additionalProperties: false });

const IOSCatalogManifestSchema = Type.Object({
  domain: Type.String({ pattern: IOS_ID_RE.source }),
  name: Type.String({ minLength: 1 }),
  description: Type.Optional(Type.String()),
  icon: Type.Union([
    Type.Object({ asset: Type.String({ minLength: 1 }) }, { additionalProperties: false }),
    Type.Object({ system: Type.String({ minLength: 1 }) }, { additionalProperties: false }),
  ]),
  permission: Type.Optional(Type.Union([
    Type.Literal("calendar"),
    Type.Literal("contacts"),
    Type.Literal("health"),
    Type.Literal("location"),
    Type.Literal("notifications"),
    Type.Literal("reminders"),
  ])),
  supportedIOS: Type.Object({
    minimum: Type.String({ pattern: IOS_VERSION_RE.source }),
    maximum: Type.Optional(Type.String({ pattern: IOS_VERSION_RE.source })),
  }, { additionalProperties: false }),
  actions: Type.Array(IOSActionSchema),
  locales: Type.Optional(Type.Record(Type.String(), IOSLocaleSchema)),
}, { additionalProperties: false });

const MCPLocaleSchema = Type.Object({
  name: Type.Optional(Type.String({ minLength: 1 })),
  description: Type.Optional(Type.String()),
}, { additionalProperties: false });

const MCPCatalogManifestSchema = Type.Object({
  id: Type.String({ pattern: ID_RE.source }),
  name: Type.String({ minLength: 1 }),
  description: Type.Optional(Type.String()),
  endpoint: Type.String({ minLength: 1 }),
  transport: Type.Optional(Type.Union([
    Type.Literal("streamable-http"),
    Type.Literal("sse"),
  ])),
  locales: Type.Optional(Type.Record(Type.String(), MCPLocaleSchema)),
}, { additionalProperties: false });

export type IOSCatalogManifest = Static<typeof IOSCatalogManifestSchema>;
export type MCPCatalogManifest = Static<typeof MCPCatalogManifestSchema>;
export type CatalogKind = "ios" | "mcp";

export const CATALOG_ROOT = resolve(import.meta.dir, "builtin");

function compareVersions(left: string, right: string): number {
  const a = left.split(".").map(Number);
  const b = right.split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const difference = (a[i] ?? 0) - (b[i] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

function validateEndpoint(endpoint: string): string | undefined {
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    return "endpoint must be an absolute URL";
  }
  if (url.protocol !== "https:") return "endpoint must use HTTPS";
  if (!url.hostname || url.username || url.password || url.hash) return "endpoint contains unsupported URL components";
}

export function catalogDir(kind: CatalogKind, id: string): string {
  return join(CATALOG_ROOT, kind, id);
}

export function listCatalogIDs(kind: CatalogKind): string[] {
  const root = join(CATALOG_ROOT, kind);
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && (kind === "ios" ? IOS_ID_RE : ID_RE).test(entry.name)
      && existsSync(join(root, entry.name, "manifest.json")))
    .map((entry) => entry.name)
    .sort();
}

async function readManifest(kind: CatalogKind, id: string): Promise<unknown | { error: string }> {
  const path = join(catalogDir(kind, id), "manifest.json");
  try {
    return JSON.parse(await Bun.file(path).text());
  } catch (error) {
    return { error: `${kind} ${id} manifest parse error: ${(error as Error).message}` };
  }
}

export function validateIOSManifest(id: string, raw: unknown): IOSCatalogManifest | { error: string } {
  if (!Value.Check(IOSCatalogManifestSchema, raw)) {
    return { error: `ios ${id}: invalid manifest` };
  }
  const manifest = raw as IOSCatalogManifest;
  if (manifest.domain !== id) return { error: `ios ${id}: manifest domain ${manifest.domain} does not match directory` };
  if (manifest.supportedIOS.maximum
    && compareVersions(manifest.supportedIOS.minimum, manifest.supportedIOS.maximum) > 0) {
    return { error: `ios ${id}: minimum iOS version exceeds maximum` };
  }
  const actionIDs = new Set<string>();
  const errors: string[] = [];
  for (const [index, action] of manifest.actions.entries()) {
    if (actionIDs.has(action.id)) errors.push(`actions[${index}]: duplicate id ${action.id}`);
    actionIDs.add(action.id);
    errors.push(...validateJSONSchemaProfile(action.inputSchema, `actions[${index}].inputSchema`));
    if (action.outputSchema !== null) {
      errors.push(...validateJSONSchemaProfile(action.outputSchema, `actions[${index}].outputSchema`));
    }
  }
  for (const [locale, overlay] of Object.entries(manifest.locales ?? {})) {
    for (const actionID of Object.keys(overlay.actions ?? {})) {
      if (!actionIDs.has(actionID)) errors.push(`locales.${locale}.actions: unknown id ${actionID}`);
    }
  }
  if (errors.length) return { error: `ios ${id}: ${errors.join("; ")}` };
  return manifest;
}

export async function loadIOSManifest(id: string): Promise<IOSCatalogManifest | { error: string }> {
  const raw = await readManifest("ios", id);
  if (raw && typeof raw === "object" && "error" in raw) return raw as { error: string };
  return validateIOSManifest(id, raw);
}

export function validateMCPManifest(id: string, raw: unknown): MCPCatalogManifest | { error: string } {
  if (!Value.Check(MCPCatalogManifestSchema, raw)) {
    return { error: `mcp ${id}: invalid manifest` };
  }
  const manifest = raw as MCPCatalogManifest;
  if (manifest.id !== id) return { error: `mcp ${id}: manifest id ${manifest.id} does not match directory` };
  const endpointError = validateEndpoint(manifest.endpoint);
  return endpointError ? { error: `mcp ${id}: ${endpointError}` } : manifest;
}

export async function loadMCPManifest(id: string): Promise<MCPCatalogManifest | { error: string }> {
  const raw = await readManifest("mcp", id);
  if (raw && typeof raw === "object" && "error" in raw) return raw as { error: string };
  return validateMCPManifest(id, raw);
}

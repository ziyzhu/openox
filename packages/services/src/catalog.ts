import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  validateIOSManifest,
  validateMCPManifest,
  type CatalogKind,
  type IOSCatalogManifest,
  type MCPCatalogManifest,
} from "@openox/service-sdk/catalog";

export type { CatalogKind } from "@openox/service-sdk/catalog";

const CATALOG_ROOT = resolve(import.meta.dir, "../../../repositories/builtin");

export function catalogDir(kind: CatalogKind, id: string): string {
  const directory = kind === "ios" && id.startsWith("ios:") ? id.slice("ios:".length) : id;
  return join(CATALOG_ROOT, kind, directory);
}

async function readManifest(kind: CatalogKind, id: string): Promise<unknown | { error: string }> {
  const path = join(catalogDir(kind, id), "service.json");
  if (!existsSync(path)) return { error: `${kind} ${id} manifest not found` };
  try {
    return JSON.parse(await Bun.file(path).text());
  } catch (error) {
    return { error: `${kind} ${id} manifest parse error: ${(error as Error).message}` };
  }
}

export async function loadIOSManifest(id: string): Promise<IOSCatalogManifest | { error: string }> {
  const raw = await readManifest("ios", id);
  if (raw && typeof raw === "object" && "error" in raw) return raw as { error: string };
  const manifest = validateIOSManifest(id, raw);
  if ("error" in manifest) return manifest;
  if (!manifest.icon && !manifest.faviconUrl) {
    return { error: `ios ${id}: icon or faviconUrl is required` };
  }
  return manifest;
}

export async function loadMCPManifest(id: string): Promise<MCPCatalogManifest | { error: string }> {
  const raw = await readManifest("mcp", id);
  if (raw && typeof raw === "object" && "error" in raw) return raw as { error: string };
  return validateMCPManifest(id, raw);
}

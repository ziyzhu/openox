import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  validateServiceManifest,
  type Manifest,
  type ServiceManifest,
} from "@openox/service-sdk/manifest";
import { inspectInstaller } from "@openox/service-sdk/installer";

export const BUILTIN_REPOSITORY_ROOT = resolve(import.meta.dir, "../../../repositories/builtin");
const SOURCE_ROOT = join(BUILTIN_REPOSITORY_ROOT, "web");
export const SERVICE_ASSET_BASE_URL = "https://openox.ai/assets/services";

export function serviceAssetURL(id: string): string {
  return `${SERVICE_ASSET_BASE_URL}/${id}/favicon.png`;
}

export function sourceDirFor(domain: string): string {
  return domain.startsWith("api:")
    ? join(BUILTIN_REPOSITORY_ROOT, "api", domain.slice(4))
    : join(SOURCE_ROOT, domain);
}

async function loadActions(
  domain: string,
): Promise<string | { error: string }> {
  const dir = sourceDirFor(domain);
  const actionsPath = join(dir, "actions.js");
  if (!existsSync(actionsPath)) return { error: `service ${domain}: actions.js not found` };
  try {
    return await Bun.file(actionsPath).text();
  } catch (error) {
    return { error: `service ${domain} actions failed to load: ${(error as Error).message}` };
  }
}

async function loadManifest(
  domain: string,
): Promise<ServiceManifest | { error: string }> {
  const manifestPath = join(sourceDirFor(domain), "service.json");
  if (!existsSync(manifestPath)) return { error: `service.json not found at ${manifestPath}` };
  let raw: unknown;
  try {
    raw = JSON.parse(await Bun.file(manifestPath).text());
  } catch (e) {
    return { error: `${domain} service.json parse error: ${(e as Error).message}` };
  }
  const result = validateServiceManifest(raw);
  if (!result.ok) return { error: `invalid manifest: ${result.errors.join("; ")}` };
  if ((result.manifest.kind === "api") !== domain.startsWith("api:")) {
    return { error: `manifest kind does not match dir "${domain}"` };
  }
  if (result.manifest.domain !== domain.replace(/^api:/, "")) {
    return { error: `manifest domain "${result.manifest.domain}" does not match dir "${domain}"` };
  }
  return result.manifest;
}

export async function buildService(domain: string): Promise<
  { manifest: Manifest; actions: string } | { error: string }
> {
  const svc = await loadManifest(domain);
  if ("error" in svc) return svc;

  const loaded = await loadActions(domain);
  if (typeof loaded !== "string") return loaded;

  const installerErrors = inspectInstaller(loaded, svc);
  if (installerErrors.length) return { error: `service ${domain}: ${installerErrors.join("; ")}` };

  const dir = sourceDirFor(domain);
  const faviconUrl = existsSync(join(dir, "favicon.png"))
    ? serviceAssetURL(domain)
    : undefined;

  const manifest: Manifest = {
    ...svc,
    ...(faviconUrl ? { faviconUrl } : {}),
  };
  return { manifest, actions: loaded };
}

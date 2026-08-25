import { existsSync, readdirSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  validateServiceManifest,
  type Manifest,
  type ServiceManifest,
  HOST_PATTERN,
} from "@openox/service-sdk/manifest";
import { logInfo } from "./log.ts";
import { readSkills } from "@openox/service-sdk/skills";
import type { ActionInstaller } from "@openox/service-sdk/action";

export const SOURCE_ROOT = resolve(import.meta.dir, "builtin", "web");
export const SERVICE_ASSET_BASE_URL = "https://openox.ai/assets/services";

export function sourceDirFor(domain: string): string {
  return join(SOURCE_ROOT, domain);
}

async function loadServiceInstaller(
  domain: string,
): Promise<{ installer: ActionInstaller; actionsPath: string } | { error: string }> {
  const dir = sourceDirFor(domain);
  const actionsPath = ["actions.ts", "actions.js"]
    .map((n) => join(dir, n))
    .find((p) => existsSync(p));
  if (!actionsPath) {
    return { error: `service ${domain}: actions.ts / actions.js not found` };
  }
  let mod: { default?: unknown };
  try {
    const source = await Bun.file(actionsPath).text();
    const hash = new Bun.CryptoHasher("sha256").update(source).digest("hex").slice(0, 16);
    mod = await import(`${pathToFileURL(actionsPath).href}?v=${hash}`) as { default?: unknown };
  } catch (e) {
    return { error: `service ${domain} actions failed to load: ${(e as Error).message}` };
  }
  const fn = mod.default;
  if (typeof fn !== "function") {
    return { error: `service ${domain}: actions must default-export a single install function` };
  }
  return { installer: fn as ActionInstaller, actionsPath };
}

function inspectInstaller(
  domain: string,
  manifest: ServiceManifest,
  installer: ActionInstaller,
): { ok: true } | { error: string } {
  const actions: Record<string, (args: any) => any> = {};
  const stub = () => { throw new Error("not callable during registration inspection"); };
  try {
    installer({
      action: (name: string, def: { invoke?: (args: any) => any }) => {
        if (actions[name]) throw new Error(`duplicate action: ${name}`);
        if (typeof def?.invoke !== "function") throw new Error(`action ${name} has no invoke function`);
        actions[name] = def.invoke;
      },
      retryFetch: stub,
      log: () => {},
    });
  } catch (e) {
    return { error: `installer threw during registration: ${(e as Error).message}` };
  }
  const declared = new Set(manifest.actions.map((action) => action.id));
  const registered = new Set(Object.keys(actions));
  const missing = [...declared].filter((id) => !registered.has(id)).sort();
  const extra = [...registered].filter((id) => !declared.has(id)).sort();
  if (missing.length || extra.length) {
    const parts = [
      missing.length ? `missing implementations: ${missing.join(", ")}` : "",
      extra.length ? `undeclared implementations: ${extra.join(", ")}` : "",
    ].filter(Boolean);
    return { error: `service ${domain}: action registration mismatch; ${parts.join("; ")}` };
  }

  return { ok: true };
}

async function getServiceManifestRaw(
  domain: string,
): Promise<ServiceManifest | { error: string }> {
  const manifestPath = join(sourceDirFor(domain), "manifest.json");
  if (!existsSync(manifestPath)) return { error: `manifest.json not found at ${manifestPath}` };
  let raw: unknown;
  try {
    raw = JSON.parse(await Bun.file(manifestPath).text());
  } catch (e) {
    return { error: `${domain} manifest.json parse error: ${(e as Error).message}` };
  }
  const result = validateServiceManifest(raw);
  if (!result.ok) return { error: `invalid manifest: ${result.errors.join("; ")}` };
  if (result.manifest.domain !== domain) {
    return { error: `manifest domain "${result.manifest.domain}" does not match dir "${domain}"` };
  }
  return result.manifest;
}

// Returns the full manifest, locale overlays included; the device localizes
// offline from the published `locales` blob.
async function loadService(domain: string): Promise<
  { manifest: Manifest; actionsPath: string } | { error: string }
> {
  const svc = await getServiceManifestRaw(domain);
  if ("error" in svc) return svc;

  const loaded = await loadServiceInstaller(domain);
  if ("error" in loaded) return loaded;

  const inspected = inspectInstaller(domain, svc, loaded.installer);
  if ("error" in inspected) return inspected;

  const dir = sourceDirFor(domain);
  const skillResult = readSkills(dir);
  if (!skillResult.ok) return { error: `service ${domain}: ${skillResult.error}` };
  const faviconUrl = existsSync(join(dir, "favicon.png"))
    ? `${SERVICE_ASSET_BASE_URL}/${domain}/favicon.png`
    : undefined;

  const manifest: Manifest = {
    ...svc,
    ...(faviconUrl ? { faviconUrl } : {}),
    ...(skillResult.skills.length ? { skills: skillResult.skills } : {}),
  };
  return { manifest, actionsPath: loaded.actionsPath };
}

export async function buildService(
  domain: string,
): Promise<{ manifest: Manifest; actions: string } | { error: string }> {
  const service = await loadService(domain);
  if ("error" in service) return service;
  const actions = await renderActions(domain, service.actionsPath);
  if (typeof actions !== "string") return actions;
  return {
    manifest: service.manifest,
    actions,
  };
}

export async function getManifest(domain: string): Promise<Manifest | { error: string }> {
  const service = await loadService(domain);
  return "error" in service ? service : service.manifest;
}

async function renderActions(
  domain: string,
  actionsPath: string,
): Promise<string | { error: string }> {
  const runtimePath = fileURLToPath(import.meta.resolve("@openox/service-sdk/action-runtime"));
  const entrySource = [
    `import install from ${JSON.stringify(actionsPath)};`,
    `import { installService } from ${JSON.stringify(runtimePath)};`,
    `installService(${JSON.stringify(domain)}, install);`,
  ].join("\n");
  const hash = new Bun.CryptoHasher("sha256").update(entrySource).digest("hex").slice(0, 16);
  const entryPath = join(tmpdir(), `ox-service-entry-${hash}.ts`);
  await Bun.write(entryPath, entrySource);
  const result = await Bun.build({
    entrypoints: [entryPath],
    root: resolve(import.meta.dir, ".."),
    target: "browser",
    format: "iife",
    minify: false,
    sourcemap: "none",
  });
  if (!result.success || !result.outputs[0]) {
    return { error: `service ${domain} actions failed to bundle: ${result.logs.map(String).join("; ")}` };
  }
  const entryName = basename(entryPath);
  const js = (await result.outputs[0].text())
    .split("\n")
    .filter(line => !line.trim().endsWith(`/${entryName}`))
    .map(line => line
      .replace("  // ../service-sdk/", "  // service-sdk/")
      .replace("  // builtin/web/", "  // services/builtin/web/"))
    .join("\n");
  logInfo(`build actions ${domain} bytes=${js.length}`);
  return js;
}

export function listServiceDomains(): string[] {
  if (!existsSync(SOURCE_ROOT)) return [];
  return readdirSync(SOURCE_ROOT, { withFileTypes: true })
    .filter((e) => e.isDirectory() && HOST_PATTERN.test(e.name)
      && existsSync(join(SOURCE_ROOT, e.name, "manifest.json")))
    .map((e) => e.name)
    .sort();
}

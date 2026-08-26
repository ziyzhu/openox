import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  validateServiceManifest,
  type Manifest,
  type ServiceManifest,
} from "@openox/service-sdk/manifest";
import { readSkills } from "@openox/service-sdk/skills";

export const BUILTIN_REPOSITORY_ROOT = resolve(import.meta.dir, "../../../repositories/builtin");
const SOURCE_ROOT = join(BUILTIN_REPOSITORY_ROOT, "web");
export const SERVICE_ASSET_BASE_URL = "https://openox.ai/assets/services";

export function sourceDirFor(domain: string): string {
  return join(SOURCE_ROOT, domain);
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

function inspectActions(
  domain: string,
  manifest: ServiceManifest,
  source: string,
): { ok: true } | { error: string } {
  const actions: Record<string, (args: any) => any> = {};
  const stub = () => { throw new Error("not callable during registration inspection"); };
  let installations = 0;
  const window = {
    ox: {
      install: (version: unknown, installer: unknown) => {
        installations++;
        if (installations > 1) throw new Error("service installer may run only once");
        if (version !== 1) throw new Error(`unsupported service action ABI: ${String(version)}`);
        if (typeof installer !== "function") throw new Error("service installer must be a function");
        const result = installer({
          action: (name: string, definition: { invoke?: (args: any) => any }) => {
            if (typeof name !== "string" || !name) throw new Error("action name must be a non-empty string");
            if (actions[name]) throw new Error(`duplicate action: ${name}`);
            if (typeof definition?.invoke !== "function") throw new Error(`action ${name} has no invoke function`);
            actions[name] = definition.invoke;
          },
          retryFetch: stub,
          log: () => {},
          lib: {
            cookie: stub,
            cleanText: (value: unknown) => String(value ?? "").replace(/\s+/g, " ").trim(),
            pageCursor: (value: string | undefined, firstPage: number) =>
              Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage),
          },
        });
        if (result && typeof result.then === "function") throw new Error("service installer must be synchronous");
      },
    },
  };
  try {
    new Function("window", source)(window);
  } catch (error) {
    return { error: `service ${domain} actions failed to register: ${(error as Error).message}` };
  }
  if (installations !== 1) return { error: `service ${domain}: actions must install exactly once` };
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
  if (result.manifest.domain !== domain) {
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

  const inspected = inspectActions(domain, svc, loaded);
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
  return { manifest, actions: loaded };
}

import { basename, dirname, isAbsolute, resolve } from "node:path";
import { qaConfig, qaNumberedDevice } from "./qa-config.ts";

export const DEFAULT_API_KEYS_PATH = "secrets/API_KEYS.json";
export const MAX_BOOTSTRAP_BYTES = 64 * 1024 * 1024;

export type LLMRegion = "global" | "china";
export type APIKeyValue = Partial<Record<LLMRegion, string>>;
export type APIKeys = Record<string, APIKeyValue>;

export type BootstrapArtifact = {
  path: string;
  name?: string;
};

export type BootstrapProfile = {
  version: 1;
  artifacts: BootstrapArtifact[];
  providers: string[];
  websiteData: boolean;
};

export type BootstrapOptions = {
  device: string;
  debugPort: number;
  apiKeysPath: string;
  profilePath?: string;
  websiteDataSource?: string;
  websiteDataSourceDebugPort?: number;
};

export type PreparedArtifact = {
  path: string;
  name: string;
  bytes: number;
  data: string;
};

export type PreparedBootstrap = {
  artifacts: PreparedArtifact[];
  credentials: Array<{ clientId: string; key: string }>;
  websiteData: boolean;
};

type ReadAPIKey = (clientId: string) => Promise<string | null>;

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`${label} must be a non-empty string`);
  return value.trim();
}

function providerID(value: unknown, label: string): string {
  const id = requiredString(value, label);
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(id)) throw new Error(`${label} contains unsupported characters`);
  return id;
}

function apiKeyValue(value: unknown, label: string): APIKeyValue {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object keyed by region`);
  }
  const source = value as Record<string, unknown>;
  const unknown = Object.keys(source).filter((key) => key !== "global" && key !== "china");
  if (unknown.length > 0) throw new Error(`${label} has unknown region ${unknown[0]}`);
  const regional = Object.fromEntries(
    (["global", "china"] as const)
      .filter((region) => source[region] !== undefined)
      .map((region) => [region, requiredString(source[region], `${label}.${region}`)]),
  );
  if (Object.keys(regional).length === 0) throw new Error(`${label} must declare global or china`);
  return regional;
}

export function parseAPIKeys(value: unknown): APIKeys {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("API keys must be an object keyed by provider ID");
  }
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length === 0) throw new Error("API keys must declare at least one provider");
  return Object.fromEntries(entries.map(([clientId, key]) => {
    const id = providerID(clientId, "provider ID");
    return [id, apiKeyValue(key, id)];
  }));
}

export function apiKeyFor(keys: APIKeys, clientId: string, region: LLMRegion): string | null {
  return keys[clientId]?.[region] ?? null;
}

function artifact(value: unknown, index: number): BootstrapArtifact {
  if (typeof value === "string") return { path: requiredString(value, `artifacts[${index}]`) };
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`artifacts[${index}] must be a path or object`);
  }
  const entry = value as Record<string, unknown>;
  const keys = Object.keys(entry).filter((key) => key !== "path" && key !== "name");
  if (keys.length > 0) throw new Error(`artifacts[${index}] has unknown field ${keys[0]}`);
  return {
    path: requiredString(entry.path, `artifacts[${index}].path`),
    name: entry.name === undefined ? undefined : requiredString(entry.name, `artifacts[${index}].name`),
  };
}

export function parseBootstrapProfile(value: unknown): BootstrapProfile {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("profile must be an object");
  const source = value as Record<string, unknown>;
  const keys = Object.keys(source).filter((key) => !["version", "artifacts", "providers", "websiteData"].includes(key));
  if (keys.length > 0) throw new Error(`profile has unknown field ${keys[0]}`);
  if (source.version !== 1) throw new Error("profile version must be 1");
  const artifacts = source.artifacts === undefined ? [] : source.artifacts;
  const providers = source.providers === undefined ? [] : source.providers;
  const websiteData = source.websiteData === undefined ? false : source.websiteData;
  if (!Array.isArray(artifacts)) throw new Error("artifacts must be an array");
  if (!Array.isArray(providers)) throw new Error("providers must be an array");
  if (typeof websiteData !== "boolean") throw new Error("websiteData must be a boolean");
  const parsedProviders = providers.map((value, index) => providerID(value, `providers[${index}]`));
  if (new Set(parsedProviders).size !== parsedProviders.length) throw new Error("providers must not contain duplicates");
  const profile = {
    version: 1 as const,
    artifacts: artifacts.map(artifact),
    providers: parsedProviders,
    websiteData,
  };
  if (profile.artifacts.length === 0 && profile.providers.length === 0 && !profile.websiteData) {
    throw new Error("profile must declare at least one artifact, provider, or websiteData snapshot");
  }
  return profile;
}

function option(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index < 0) return undefined;
  return requiredString(args[index + 1], name);
}

export function parseBootstrapOptions(
  args: string[],
  environmentDevice: string | undefined,
  root: string,
): BootstrapOptions {
  const allowed = new Set(["--device", "--keys", "--profile", "--website-data-from"]);
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!allowed.has(arg)) throw new Error(`unknown argument ${arg}`);
    index += 1;
    if (args[index] === undefined) throw new Error(`${arg} requires a value`);
  }
  const device = qaNumberedDevice(args, environmentDevice);
  const keys = option(args, "--keys") ?? DEFAULT_API_KEYS_PATH;
  const profile = option(args, "--profile");
  const websiteDataSource = option(args, "--website-data-from");
  if (websiteDataSource) qaNumberedDevice(["--device", websiteDataSource], undefined);
  if (websiteDataSource === device) throw new Error("website data source and target must be different simulators");
  return {
    device,
    debugPort: qaConfig(device).debugPort,
    apiKeysPath: isAbsolute(keys) ? keys : resolve(root, keys),
    profilePath: profile === undefined ? undefined : isAbsolute(profile) ? profile : resolve(root, profile),
    websiteDataSource,
    websiteDataSourceDebugPort: websiteDataSource ? qaConfig(websiteDataSource).debugPort : undefined,
  };
}

export async function loadAPIKeys(path: string): Promise<APIKeys> {
  const file = Bun.file(path);
  if (!(await file.exists())) throw new Error(`API key file not found: ${path}`);
  let value: unknown;
  try {
    value = await file.json();
  } catch (error) {
    throw new Error(`invalid API key file ${path}: ${(error as Error).message}`);
  }
  return parseAPIKeys(value);
}

export async function loadBootstrapProfile(path: string): Promise<BootstrapProfile> {
  const file = Bun.file(path);
  if (!(await file.exists())) throw new Error(`bootstrap profile not found: ${path}`);
  let value: unknown;
  try {
    value = await file.json();
  } catch (error) {
    throw new Error(`invalid bootstrap profile ${path}: ${(error as Error).message}`);
  }
  return parseBootstrapProfile(value);
}

export async function prepareBootstrap(
  profilePath: string,
  profile: BootstrapProfile,
  readAPIKey: ReadAPIKey,
): Promise<PreparedBootstrap> {
  const directory = dirname(profilePath);
  const artifacts: PreparedArtifact[] = [];
  let totalBytes = 0;
  for (const entry of profile.artifacts) {
    const path = isAbsolute(entry.path) ? entry.path : resolve(directory, entry.path);
    const file = Bun.file(path);
    if (!(await file.exists())) throw new Error(`bootstrap artifact not found: ${path}`);
    const data = new Uint8Array(await file.arrayBuffer());
    totalBytes += data.byteLength;
    if (totalBytes > MAX_BOOTSTRAP_BYTES) {
      throw new Error(`bootstrap artifacts exceed ${MAX_BOOTSTRAP_BYTES} bytes`);
    }
    artifacts.push({
      path,
      name: entry.name ?? basename(path),
      bytes: data.byteLength,
      data: data.toBase64(),
    });
  }
  const credentials: Array<{ clientId: string; key: string }> = [];
  const missing: string[] = [];
  for (const clientId of profile.providers) {
    const key = (await readAPIKey(clientId))?.trim();
    if (key) credentials.push({ clientId, key });
    else missing.push(clientId);
  }
  if (missing.length > 0) {
    throw new Error(`missing API keys for ${missing.join(", ")}`);
  }
  return { artifacts, credentials, websiteData: profile.websiteData };
}

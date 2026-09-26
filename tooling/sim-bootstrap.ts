import { basename, dirname, isAbsolute, resolve } from "node:path";
import { callHost } from "../apps/cli/src/host-rpc.ts";
import { ROOT, run } from "./lib.ts";
import { qaCommand, qaConfig } from "./qa-config.ts";

const MAX_BOOTSTRAP_BYTES = 64 * 1024 * 1024;
const REGIONS = ["global", "china"] as const;

type LLMRegion = typeof REGIONS[number];
type APIKeys = Record<string, Partial<Record<LLMRegion, string>>>;
type BootstrapProfile = {
  version: 1;
  artifacts: Array<{ path: string; name?: string }>;
  providers: string[];
  websiteData: boolean;
};

const usage = `Usage: bun run sim:bootstrap --device ox-qa-N [options]

Bootstraps credentials, artifacts, and optional website data into a running DEBUG app.

Options:
  --device <ox-qa-N>             Target numbered simulator
  --keys <path>                  API key file (default secrets/API_KEYS.json)
  --profile <path>               Bootstrap profile describing artifacts, providers, and website data
  --website-data-from <ox-qa-N>  Copy website data from another running simulator
  -h, --help                     Display this help`;

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`${label} must be a non-empty string`);
  return value.trim();
}

function providerID(value: unknown, label: string): string {
  const id = requiredString(value, label);
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(id)) throw new Error(`${label} contains unsupported characters`);
  return id;
}

function record(value: unknown, label: string, allowed?: readonly string[]): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  const unknown = allowed ? Object.keys(value).filter((key) => !allowed.includes(key)) : [];
  if (unknown.length > 0) throw new Error(`${label} has unknown field ${unknown[0]}`);
  return value as Record<string, unknown>;
}

function parseAPIKeys(value: unknown): APIKeys {
  const entries = Object.entries(record(value, "API keys"));
  if (entries.length === 0) throw new Error("API keys must declare at least one provider");
  return Object.fromEntries(entries.map(([clientId, regional]) => {
    const id = providerID(clientId, "provider ID");
    const source = record(regional, id, REGIONS);
    const keys = Object.fromEntries(REGIONS
      .filter((region) => source[region] !== undefined)
      .map((region) => [region, requiredString(source[region], `${id}.${region}`)]));
    if (Object.keys(keys).length === 0) throw new Error(`${id} must declare global or china`);
    return [id, keys];
  }));
}

function parseArtifact(value: unknown, index: number): BootstrapProfile["artifacts"][number] {
  const label = `artifacts[${index}]`;
  if (typeof value === "string") return { path: requiredString(value, label) };
  const entry = record(value, label, ["path", "name"]);
  return {
    path: requiredString(entry.path, `${label}.path`),
    name: entry.name === undefined ? undefined : requiredString(entry.name, `${label}.name`),
  };
}

function parseBootstrapProfile(value: unknown): BootstrapProfile {
  const { version, artifacts = [], providers = [], websiteData = false } = record(value, "profile", ["version", "artifacts", "providers", "websiteData"]);
  if (version !== 1) throw new Error("profile version must be 1");
  if (!Array.isArray(artifacts)) throw new Error("artifacts must be an array");
  if (!Array.isArray(providers)) throw new Error("providers must be an array");
  if (typeof websiteData !== "boolean") throw new Error("websiteData must be a boolean");
  const parsedProviders = providers.map((provider, index) => providerID(provider, `providers[${index}]`));
  if (new Set(parsedProviders).size !== parsedProviders.length) throw new Error("providers must not contain duplicates");
  if (artifacts.length === 0 && parsedProviders.length === 0 && !websiteData) {
    throw new Error("profile must declare at least one artifact, provider, or websiteData snapshot");
  }
  return { version: 1, artifacts: artifacts.map(parseArtifact), providers: parsedProviders, websiteData };
}

async function readJSON(path: string, label: string): Promise<unknown> {
  const file = Bun.file(path);
  if (!await file.exists()) throw new Error(`${label} not found: ${path}`);
  try {
    return await file.json();
  } catch (error) {
    throw new Error(`invalid ${label} ${path}: ${(error as Error).message}`);
  }
}

async function readArtifacts(directory: string, artifacts: BootstrapProfile["artifacts"]) {
  let totalBytes = 0;
  const prepared = [];
  for (const entry of artifacts) {
    const path = resolve(directory, entry.path);
    const file = Bun.file(path);
    if (!await file.exists()) throw new Error(`bootstrap artifact not found: ${path}`);
    const data = new Uint8Array(await file.arrayBuffer());
    totalBytes += data.byteLength;
    if (totalBytes > MAX_BOOTSTRAP_BYTES) throw new Error(`bootstrap artifacts exceed ${MAX_BOOTSTRAP_BYTES} bytes`);
    prepared.push({ path, name: entry.name ?? basename(path), bytes: data.byteLength, data: data.toBase64() });
  }
  return prepared;
}

async function requireBooted(requested: string[]): Promise<void> {
  const { stdout } = await run(["sim", "devices"], { capture: true });
  const output = JSON.parse(stdout) as {
    devices?: Record<string, Array<{ name?: string; state?: string; isAvailable?: boolean }>>;
  };
  const devices = Object.values(output.devices ?? {}).flat();
  for (const device of requested) {
    const target = devices.find((candidate) => candidate.name === device && candidate.isAvailable !== false);
    if (!target) throw new Error(`simulator not found: ${device}`);
    if (target.state !== "Booted") throw new Error(`simulator ${device} is ${target.state ?? "unavailable"}; launch it before bootstrap`);
  }
}

async function simulatorRegion(endpoint: string): Promise<LLMRegion> {
  const { region } = await callHost("models.list", {}, 10_000, endpoint);
  if (region !== "global" && region !== "china") throw new Error("simulator region lookup returned an invalid result");
  return region;
}

async function bootstrap(): Promise<void> {
  const target = qaCommand({
    usage,
    options: {
      keys: { type: "string", default: "secrets/API_KEYS.json" },
      profile: { type: "string" },
      "website-data-from": { type: "string" },
    },
  });
  const source = target.values["website-data-from"] ? qaConfig(target.values["website-data-from"]) : undefined;
  if (source?.device === target.device) throw new Error("website data source and target must be different simulators");
  const apiKeysPath = resolve(ROOT, target.values.keys!);
  const profilePath = target.values.profile ? resolve(ROOT, target.values.profile) : undefined;
  const configuredProfile = profilePath ? parseBootstrapProfile(await readJSON(profilePath, "bootstrap profile")) : undefined;
  const needsCredentials = configuredProfile === undefined || configuredProfile.providers.length > 0;
  const apiKeys = needsCredentials ? parseAPIKeys(await readJSON(apiKeysPath, "API key file")) : {};
  const profile = configuredProfile ?? { version: 1, artifacts: [], providers: Object.keys(apiKeys), websiteData: false };
  if (profile.websiteData && !source) throw new Error("profile websiteData requires --website-data-from ox-qa-N");
  if (!profile.websiteData && source) throw new Error("--website-data-from requires websiteData: true in the profile");

  await requireBooted([target.device, ...(source ? [source.device] : [])]);
  const region = needsCredentials ? await simulatorRegion(target.debugEndpoint) : undefined;
  const artifacts = await readArtifacts(dirname(profilePath ?? apiKeysPath), profile.artifacts);
  const credentials = profile.providers.map((clientId) => ({ clientId, key: region && apiKeys[clientId]?.[region]?.trim() }));
  const missing = credentials.filter(({ key }) => !key).map(({ clientId }) => clientId);
  if (missing.length > 0) throw new Error(`missing API keys for ${missing.join(", ")}`);

  if (source) {
    const exported = await callHost("debug.websiteData.export", {}, 60_000, source.debugEndpoint);
    if (typeof exported.data !== "string" || typeof exported.bytes !== "number") {
      throw new Error("website data export returned an invalid result");
    }
    await callHost("debug.websiteData.restore", { data: exported.data }, 60_000, target.debugEndpoint);
    console.log(`Website data: restored ${exported.bytes} bytes from ${source.device}`);
  }
  if (artifacts.length > 0) {
    const result = await callHost("debug.artifacts.bootstrap", {
      artifacts: artifacts.map(({ name, data }) => ({ name, data })),
    }, 60_000, target.debugEndpoint);
    const installed = result.artifacts as string[] | undefined;
    if (!installed || installed.length !== artifacts.length) throw new Error("artifact bootstrap returned an invalid result");
    artifacts.forEach((artifact, index) => console.log(`Artifact ${artifact.path} -> ${installed[index]} (${artifact.bytes} bytes)`));
  }
  for (const { clientId, key } of credentials) {
    await callHost("debug.providers.setKey", { clientId, key, region }, 10_000, target.debugEndpoint);
    console.log(`Provider ${clientId}: ready`);
  }
  console.log(`BOOTSTRAPPED ${target.device} region=${region ?? "none"} providers=${credentials.length}`);
}

try {
  await bootstrap();
} catch (error) {
  console.error(`error: ${(error as Error).message}`);
  process.exitCode = 1;
}

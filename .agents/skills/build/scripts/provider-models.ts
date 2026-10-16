import { join } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";

const source = "https://models.dev/catalog.json";
const providersPath = join(ROOT, "apps/shared/Host/ModelProviders/providers.json");
const catalogPath = join(ROOT, "apps/shared/Host/ModelProviders/provider-catalog.json");
const formats = new Set(["openai", "gemini", "chatgpt", "anthropic"]);
const ruleOptions = new Set(["serviceTier", "adaptiveThinking", "replayReasoning"]);

type CatalogModel = {
  name?: string;
  status?: string;
  tool_call?: boolean;
  reasoning?: boolean;
  reasoning_options?: Array<{ type?: string; values?: Array<string | null> }>;
  modalities?: { input?: string[]; output?: string[] };
  limit?: { context?: number; output?: number };
};

type Rule = { match?: unknown; exclude?: unknown; options?: Record<string, unknown>; outputTokens?: unknown };
type BundledProvider = {
  definition?: { id?: unknown };
  legacyID?: unknown;
  legacyCredentialID?: unknown;
  discovery?: { format?: unknown; catalog?: unknown; rules?: Rule[] };
};

type SnapshotModel = {
  id: string;
  displayName: string;
  maxTokens: number;
  maxContext: number;
  supportsTools: true;
  reasoning: boolean;
  reasoningEfforts: string[];
  modalities: { input: string[]; output: string[] };
};

function fail(message: string): never {
  throw new Error(message);
}

async function readJSON<T>(path: string): Promise<T> {
  const file = Bun.file(path);
  if (!await file.exists()) fail(`missing ${path}`);
  return JSON.parse(await file.text()) as T;
}

function catalogIDs(providers: BundledProvider[]): string[] {
  return [...new Set(providers.flatMap((entry) => typeof entry.discovery?.catalog === "string" ? [entry.discovery.catalog] : []))].sort();
}

function snapshotModel(id: string, model: CatalogModel): SnapshotModel | undefined {
  const input = model.modalities?.input ?? [];
  const output = model.modalities?.output ?? [];
  const context = model.limit?.context ?? 0;
  const limit = model.limit?.output ?? 0;
  if ((model.status && model.status !== "active") || model.tool_call !== true) return undefined;
  if (!input.includes("text") || !output.includes("text") || context <= 0 || limit <= 0) return undefined;
  const reasoningEfforts = model.reasoning_options
    ?.filter((option) => option.type === "effort")
    .flatMap((option) => option.values ?? [])
    .filter((value): value is string => value !== null) ?? [];
  return {
    id,
    displayName: model.name || id,
    maxTokens: Math.min(limit, context),
    maxContext: context,
    supportsTools: true,
    reasoning: Boolean(model.reasoning),
    reasoningEfforts,
    modalities: { input: [...input].sort(), output: [...output].sort() },
  };
}

function validateProviders(providers: BundledProvider[], snapshot: Record<string, SnapshotModel[]>): number {
  const ids = new Set<string>();
  for (const entry of providers) {
    const id = entry.definition?.id;
    if (typeof id !== "string" || ids.has(id)) fail(`providers.json has a missing or repeated id: ${String(id)}`);
    ids.add(id);
    if (typeof entry.legacyID !== "string" || typeof entry.legacyCredentialID !== "string") fail(`${id} needs legacy identifiers`);
    const discovery = entry.discovery;
    if (!discovery) continue;
    if (!formats.has(String(discovery.format))) fail(`${id} uses unknown discovery format ${String(discovery.format)}`);
    if (discovery.catalog !== undefined && !snapshot[String(discovery.catalog)]) fail(`${id} references missing catalog ${String(discovery.catalog)}`);
    for (const rule of discovery.rules ?? []) {
      if (typeof rule.match !== "string" || rule.match.length === 0) fail(`${id} has a rule without match`);
      if (rule.exclude !== undefined && typeof rule.exclude !== "boolean") fail(`${id} has an invalid exclude rule`);
      if (rule.outputTokens !== undefined && !(Number.isInteger(rule.outputTokens) && Number(rule.outputTokens) > 0)) fail(`${id} has an invalid outputTokens rule`);
      for (const key of Object.keys(rule.options ?? {})) if (!ruleOptions.has(key)) fail(`${id} has an unsupported rule option ${key}`);
    }
  }
  return ids.size;
}

export async function check(): Promise<string> {
  const providers = await readJSON<BundledProvider[]>(providersPath);
  const snapshot = await readJSON<Record<string, SnapshotModel[]>>(catalogPath);
  const missing = catalogIDs(providers).filter((id) => !snapshot[id]);
  if (missing.length > 0) fail(`provider catalog is missing ${missing.join(", ")}; run bun run update:llms`);
  const count = validateProviders(providers, snapshot);
  const models = Object.values(snapshot).reduce((total, list) => total + list.length, 0);
  return `providers=${count} catalogs=${Object.keys(snapshot).length} catalogModels=${models}`;
}

async function update(): Promise<void> {
  const [response, providers] = await Promise.all([
    fetch(source, { headers: { Accept: "application/json" } }),
    readJSON<BundledProvider[]>(providersPath),
  ]);
  if (!response.ok) fail(`${source} returned HTTP ${response.status}`);
  const catalog = (await response.json() as { providers?: Record<string, { models?: Record<string, CatalogModel> }> }).providers ?? {};
  const snapshot: Record<string, SnapshotModel[]> = {};
  for (const id of catalogIDs(providers)) {
    const models = catalog[id]?.models ?? fail(`models.dev has no provider ${id}`);
    snapshot[id] = Object.entries(models)
      .flatMap(([modelID, model]) => snapshotModel(modelID, model) ?? [])
      .sort((a, b) => a.id.localeCompare(b.id));
  }
  await Bun.write(catalogPath, `${JSON.stringify(snapshot, null, 1)}\n`);
}

if (import.meta.main) {
  await update();
  await runCheck(check);
}

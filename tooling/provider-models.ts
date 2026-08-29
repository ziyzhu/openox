import { join } from "node:path";
import { ROOT, fail } from "./lib.ts";

const source = "https://models.dev/catalog.json";
const manifestPath = join(ROOT, "apps/ios/Ox/Host/ModelProviders/provider-models.json");
const expectedClients = {
  global: [
    "chatgpt", "openai", "anthropic", "gemini", "github-copilot", "xai", "opencode-go",
    "qwen-coding-plan", "minimax-token-plan", "openrouter", "amazon-bedrock", "mistral",
    "kimi", "deepseek", "zai-coding-plan", "zai", "qwen",
  ],
  china: [
    "qwen-coding-plan", "minimax-token-plan", "kimi", "deepseek", "zai-coding-plan",
    "zai", "qwen", "minimax", "stepfun", "siliconflow",
  ],
} as const;

type Catalog = {
  providers?: Record<string, CatalogProvider>;
};

type CatalogProvider = {
  models?: Record<string, CatalogModel>;
};

type CatalogModel = {
  id?: string;
  name?: string;
  status?: string;
  tool_call?: boolean;
  reasoning?: boolean;
  reasoning_options?: Array<{
    type?: string;
    values?: Array<string | null>;
  }>;
  modalities?: ModelModalities;
  limit?: {
    context?: number;
    output?: number;
  };
};

type ProviderModelsFile = {
  providers?: Record<string, ProviderSelection>;
};

type ProviderSelection = {
  global?: RegionalSelection;
  china?: RegionalSelection;
};

type RegionalSelection = {
  catalogProvider?: string;
  models?: ModelEntry[];
};

type ModelEntry = {
  source?: string;
  overrides?: ModelOverrides;
  model?: ResolvedModel;
};

type ModelOverrides = {
  id?: string;
  providerModelID?: string;
  displayName?: string;
  variant?: string;
  maxTokens?: number;
  maxContext?: number;
};

type ModelModalities = {
  input?: string[];
  output?: string[];
};

type ResolvedModel = {
  id: string;
  providerModelID?: string;
  variant?: string;
  displayName: string;
  maxTokens: number;
  maxContext: number;
  supportsTools: boolean;
  reasoning: boolean;
  reasoningEfforts: string[];
  modalities: {
    input: string[];
    output: string[];
  };
};

type ProviderModelsSummary = {
  providers: number;
  selectedModels: number;
};

function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  return value as Record<string, unknown>;
}

function positiveInteger(value: unknown, label: string): number {
  if (!Number.isInteger(value) || Number(value) <= 0) fail(`${label} must be a positive integer`);
  return Number(value);
}

function nonEmptyString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim().length === 0) fail(`${label} must be a non-empty string`);
  return String(value);
}

function parse<T>(text: string, label: string): T {
  try {
    return object(JSON.parse(text), label) as T;
  } catch (error) {
    return fail(`${label} is invalid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function validateStructure(manifest: ProviderModelsFile): ProviderModelsSummary {
  const providers = object(manifest.providers, "provider models.providers") as Record<string, ProviderSelection>;
  let selectedModels = 0;

  for (const [clientID, providerSelection] of Object.entries(providers)) {
    const unknownRegions = Object.keys(providerSelection).filter((region) => region !== "global" && region !== "china");
    if (unknownRegions.length > 0) fail(`provider ${clientID} has unknown regions ${unknownRegions.join(", ")}`);
    const regionalSelections = Object.entries(providerSelection).filter(
      (entry): entry is [string, RegionalSelection] => entry[0] === "global" || entry[0] === "china",
    );
    if (regionalSelections.length === 0) fail(`provider ${clientID} must include a region`);
    for (const [region, regionalSelection] of regionalSelections) {
      const label = `${clientID}.${region}`;
      nonEmptyString(regionalSelection.catalogProvider, `${label}.catalogProvider`);
      const models = Array.isArray(regionalSelection.models) && regionalSelection.models.length > 0
        ? regionalSelection.models
        : fail(`${label} must include models`);
      const ids = new Set<string>();
      for (const entry of models) {
        const sourceID = nonEmptyString(entry.source, `${label}.source`);
        const model = entry.model ?? fail(`${label}/${sourceID} has no resolved model`);
        const id = nonEmptyString(model.id, `${label}/${sourceID}.id`);
        if (ids.has(id)) fail(`${label} repeats model id ${id}`);
        ids.add(id);
        nonEmptyString(model.displayName, `${label}/${id}.displayName`);
        positiveInteger(model.maxTokens, `${label}/${id}.maxTokens`);
        positiveInteger(model.maxContext, `${label}/${id}.maxContext`);
        if (model.supportsTools !== true) fail(`${label}/${id} does not support tools`);
        if (typeof model.reasoning !== "boolean") fail(`${label}/${id} has no reasoning capability`);
        if (!Array.isArray(model.reasoningEfforts)) fail(`${label}/${id}.reasoningEfforts must be an array`);
        if (!model.modalities?.input?.includes("text") || !model.modalities.output?.includes("text")) {
          fail(`${label}/${id} must accept and produce text`);
        }
        selectedModels += 1;
      }
    }
  }

  for (const [region, expected] of Object.entries(expectedClients)) {
    const actual = Object.entries(providers)
      .filter(([, providerSelection]) => providerSelection[region as keyof ProviderSelection] !== undefined)
      .map(([clientID]) => clientID);
    if (actual.join(",") !== expected.join(",")) {
      fail(`provider models ${region} clients differ: expected ${expected.join(",")}; received ${actual.join(",")}`);
    }
  }

  return { providers: Object.keys(providers).length, selectedModels };
}

function resolve(catalog: Catalog, configuration: ProviderModelsFile): ProviderModelsFile {
  const catalogProviders = object(catalog.providers, "catalog.providers") as Record<string, CatalogProvider>;
  const providers = object(configuration.providers, "provider models.providers") as Record<string, ProviderSelection>;
  const resolvedProviders: Record<string, ProviderSelection> = {};

  for (const [clientID, providerSelection] of Object.entries(providers)) {
    const resolvedSelection: ProviderSelection = {};
    for (const region of ["global", "china"] as const) {
      const regionalSelection = providerSelection[region];
      if (!regionalSelection) continue;
      const catalogProviderID = nonEmptyString(regionalSelection.catalogProvider, `${clientID}.${region}.catalogProvider`);
      const catalogModels = object(
        catalogProviders[catalogProviderID]?.models,
        `catalog.providers.${catalogProviderID}.models`,
      ) as Record<string, CatalogModel>;
      const models = Array.isArray(regionalSelection.models) && regionalSelection.models.length > 0
        ? regionalSelection.models
        : fail(`${clientID}.${region} must include models`);
      resolvedSelection[region] = {
        catalogProvider: catalogProviderID,
        models: models.map((entry) => resolveModel(clientID, region, catalogProviderID, catalogModels, entry)),
      };
    }
    resolvedProviders[clientID] = resolvedSelection;
  }
  return { providers: resolvedProviders };
}

function resolveModel(
  clientID: string,
  region: string,
  catalogProviderID: string,
  catalogModels: Record<string, CatalogModel>,
  entry: ModelEntry,
): ModelEntry {
  const sourceID = nonEmptyString(entry.source, `${clientID}.${region}.source`);
  const sourceModel = catalogModels[sourceID] ?? fail(`${catalogProviderID}/${sourceID} is missing`);
  const overrides = entry.overrides ?? {};
  if (sourceModel.status && sourceModel.status !== "active") {
    fail(`${catalogProviderID}/${sourceID} has unsupported status ${sourceModel.status}`);
  }
  if (sourceModel.tool_call !== true) fail(`${catalogProviderID}/${sourceID} does not support tools`);
  if (typeof sourceModel.reasoning !== "boolean") fail(`${catalogProviderID}/${sourceID} has no reasoning capability`);
  if (!sourceModel.modalities?.input?.includes("text") || !sourceModel.modalities.output?.includes("text")) {
    fail(`${catalogProviderID}/${sourceID} must accept and produce text`);
  }
  const sourceContext = positiveInteger(sourceModel.limit?.context, `${catalogProviderID}/${sourceID} context limit`);
  const sourceOutput = positiveInteger(sourceModel.limit?.output, `${catalogProviderID}/${sourceID} output limit`);
  const maxContext = overrides.maxContext === undefined
    ? sourceContext
    : positiveInteger(overrides.maxContext, `${clientID}.${region}/${sourceID} maxContext`);
  const maxTokens = overrides.maxTokens === undefined
    ? sourceOutput
    : positiveInteger(overrides.maxTokens, `${clientID}.${region}/${sourceID} maxTokens`);
  if (maxContext > sourceContext) fail(`${clientID}.${region}/${sourceID} maxContext exceeds the catalog limit`);
  if (maxTokens > sourceOutput) fail(`${clientID}.${region}/${sourceID} maxTokens exceeds the catalog limit`);
  if (overrides.variant !== undefined && overrides.variant !== "fast") {
    fail(`${clientID}.${region}/${sourceID} uses unsupported variant ${overrides.variant}`);
  }
  const id = overrides.id ?? sourceModel.id ?? sourceID;
  const providerModelID = overrides.providerModelID ?? (id === sourceID ? undefined : sourceID);
  const baseDisplayName = overrides.displayName ?? nonEmptyString(sourceModel.name, `${catalogProviderID}/${sourceID}.name`);
  const displayName = overrides.variant === "fast" ? `${baseDisplayName} · Fast` : baseDisplayName;
  const reasoningEfforts = sourceModel.reasoning_options
    ?.filter((option) => option.type === "effort")
    .flatMap((option) => option.values ?? [])
    .filter((value): value is string => value !== null) ?? [];
  const model: ResolvedModel = {
    id,
    displayName,
    maxTokens,
    maxContext,
    supportsTools: true,
    reasoning: Boolean(sourceModel.reasoning),
    reasoningEfforts,
    modalities: {
      input: [...(sourceModel.modalities?.input ?? [])],
      output: [...(sourceModel.modalities?.output ?? [])],
    },
  };
  if (providerModelID !== undefined) model.providerModelID = providerModelID;
  if (overrides.variant !== undefined) model.variant = overrides.variant;
  return {
    source: sourceID,
    ...(Object.keys(overrides).length > 0 ? { overrides } : {}),
    model,
  };
}

async function loadConfiguration(): Promise<ProviderModelsFile> {
  const manifest = Bun.file(manifestPath);
  if (!await manifest.exists()) fail(`missing ${manifestPath}`);
  return parse<ProviderModelsFile>(await manifest.text(), "provider models");
}

export async function validateProviderModels(): Promise<ProviderModelsSummary> {
  const manifest = Bun.file(manifestPath);
  if (!await manifest.exists()) fail(`missing ${manifestPath}; run bun run update:llms`);
  return validateStructure(parse<ProviderModelsFile>(await manifest.text(), "provider models"));
}

async function update(): Promise<ProviderModelsSummary> {
  const [response, configuration] = await Promise.all([
    fetch(source, { headers: { Accept: "application/json" } }),
    loadConfiguration(),
  ]);
  if (!response.ok) fail(`${source} returned HTTP ${response.status}`);
  const resolved = resolve(parse<Catalog>(await response.text(), "models.dev catalog"), configuration);
  const summary = validateStructure(resolved);
  await Bun.write(manifestPath, `${JSON.stringify(resolved, null, 2)}\n`);
  return summary;
}

if (import.meta.main) {
  const summary = await update();
  console.log(`PASS provider models update providers=${summary.providers} selected=${summary.selectedModels}`);
}

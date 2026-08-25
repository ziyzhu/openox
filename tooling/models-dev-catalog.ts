import { rename, unlink } from "node:fs/promises";
import { join } from "node:path";
import { ROOT, fail } from "./lib.ts";

const source = "https://models.dev/catalog.json";
const catalogPath = join(ROOT, "apps/ios/Ox/Host/ModelProviders/models-dev-catalog.json");
const selectionPath = join(ROOT, "apps/ios/Ox/Host/ModelProviders/models-dev-selection.json");
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
  models?: Record<string, unknown>;
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
  modalities?: {
    input?: string[];
    output?: string[];
  };
  limit?: {
    context?: number;
    output?: number;
  };
};

type SelectionFile = {
  providers?: Record<string, ProviderSelection>;
};

type ProviderSelection = {
  global?: RegionalSelection;
  china?: RegionalSelection;
};

type RegionalSelection = {
  catalogProvider?: string;
  models?: ModelSelection[];
};

type ModelSelection = {
  source?: string;
  id?: string;
  providerModelID?: string;
  displayName?: string;
  variant?: string;
  maxTokens?: number;
  maxContext?: number;
};

type CatalogSummary = {
  canonicalModels: number;
  providers: number;
  providerModels: number;
  selectedModels: number;
};

export type CatalogDrift = {
  providerID: string;
  clients: string[];
  addedCompatible: string[];
  removedCompatible: string[];
  selectedChanges: string[];
};

function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  return value as Record<string, unknown>;
}

function positiveInteger(value: unknown, label: string): number {
  if (!Number.isInteger(value) || Number(value) <= 0) fail(`${label} must be a positive integer`);
  return Number(value);
}

function parse<T>(text: string, label: string): T {
  try {
    return object(JSON.parse(text), label) as T;
  } catch (error) {
    return fail(`${label} is invalid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function compatible(model: CatalogModel | undefined): boolean {
  return Boolean(
    model
      && (!model.status || model.status === "active")
      && model.tool_call === true
      && model.modalities?.input?.includes("text")
      && model.modalities.output?.includes("text")
      && Number.isInteger(model.limit?.context)
      && Number(model.limit?.context) > 0
      && Number.isInteger(model.limit?.output)
      && Number(model.limit?.output) > 0,
  );
}

function modelFields(model: CatalogModel): Record<string, unknown> {
  return {
    id: model.id,
    name: model.name,
    status: model.status ?? "active",
    toolCall: model.tool_call,
    reasoning: model.reasoning,
    reasoningEfforts: model.reasoning_options
      ?.filter((option) => option.type === "effort")
      .flatMap((option) => option.values ?? [])
      .filter((value): value is string => value !== null)
      ?? [],
    input: [...(model.modalities?.input ?? [])].sort(),
    output: [...(model.modalities?.output ?? [])].sort(),
    context: model.limit?.context,
    outputLimit: model.limit?.output,
  };
}

function displayField(value: unknown): string {
  if (Array.isArray(value)) return value.join("|");
  return String(value);
}

function changedFields(before: CatalogModel, after: CatalogModel): string[] {
  const oldFields = modelFields(before);
  const newFields = modelFields(after);
  return Object.keys(oldFields).flatMap((key) =>
    JSON.stringify(oldFields[key]) === JSON.stringify(newFields[key])
      ? []
      : [`${key}: ${displayField(oldFields[key])} -> ${displayField(newFields[key])}`]
  );
}

export function catalogDrift(before: Catalog, after: Catalog, selection: SelectionFile): CatalogDrift[] {
  const references = new Map<string, { clients: Set<string>; selected: Set<string> }>();
  for (const [clientID, providerSelection] of Object.entries(selection.providers ?? {})) {
    for (const region of ["global", "china"] as const) {
      const regionalSelection = providerSelection[region];
      if (!regionalSelection?.catalogProvider) continue;
      const reference = references.get(regionalSelection.catalogProvider)
        ?? { clients: new Set<string>(), selected: new Set<string>() };
      reference.clients.add(`${clientID}.${region}`);
      for (const model of regionalSelection.models ?? []) {
        if (model.source) reference.selected.add(model.source);
      }
      references.set(regionalSelection.catalogProvider, reference);
    }
  }

  const drift: CatalogDrift[] = [];
  for (const [providerID, reference] of [...references].sort(([left], [right]) => left.localeCompare(right))) {
    const oldModels = before.providers?.[providerID]?.models ?? {};
    const newModels = after.providers?.[providerID]?.models ?? {};
    const modelIDs = new Set([...Object.keys(oldModels), ...Object.keys(newModels)]);
    const addedCompatible: string[] = [];
    const removedCompatible: string[] = [];
    const selectedChanges: string[] = [];
    for (const modelID of [...modelIDs].sort()) {
      const oldModel = oldModels[modelID];
      const newModel = newModels[modelID];
      const wasCompatible = compatible(oldModel);
      const isCompatible = compatible(newModel);
      if (!wasCompatible && isCompatible) addedCompatible.push(modelID);
      if (wasCompatible && !isCompatible) removedCompatible.push(modelID);
      if (reference.selected.has(modelID) && oldModel && newModel) {
        const fields = changedFields(oldModel, newModel);
        if (fields.length > 0) selectedChanges.push(`${modelID} [${fields.join(", ")}]`);
      }
    }
    if (addedCompatible.length > 0 || removedCompatible.length > 0 || selectedChanges.length > 0) {
      drift.push({
        providerID,
        clients: [...reference.clients].sort(),
        addedCompatible,
        removedCompatible,
        selectedChanges,
      });
    }
  }
  return drift;
}

function validate(catalog: Catalog, selection: SelectionFile): CatalogSummary {
  const canonicalModels = object(catalog.models, "catalog.models");
  const providers = object(catalog.providers, "catalog.providers") as Record<string, CatalogProvider>;
  const selections = object(selection.providers, "selection.providers") as Record<string, ProviderSelection>;
  let providerModels = 0;
  let selectedModels = 0;

  for (const [providerID, provider] of Object.entries(providers)) {
    providerModels += Object.keys(object(provider.models, `catalog.providers.${providerID}.models`)).length;
  }

  for (const [clientID, providerSelection] of Object.entries(selections)) {
    const unknownRegions = Object.keys(providerSelection).filter((region) => region !== "global" && region !== "china");
    if (unknownRegions.length > 0) fail(`selection provider ${clientID} has unknown regions ${unknownRegions.join(", ")}`);
    const regionalSelections = Object.entries(providerSelection).filter(
      (entry): entry is [string, RegionalSelection] => entry[0] === "global" || entry[0] === "china",
    );
    if (regionalSelections.length === 0) fail(`selection provider ${clientID} must include a region`);
    for (const [region, regionalSelection] of regionalSelections) {
      validateRegionalSelection(clientID, region, regionalSelection);
    }
  }

  for (const [region, expected] of Object.entries(expectedClients)) {
    const actual = Object.entries(selections)
      .filter(([, providerSelection]) => providerSelection[region as keyof ProviderSelection] !== undefined)
      .map(([clientID]) => clientID);
    if (actual.join(",") !== expected.join(",")) {
      fail(`selection ${region} clients differ: expected ${expected.join(",")}; received ${actual.join(",")}`);
    }
  }

  function validateRegionalSelection(
    clientID: string,
    region: string,
    providerSelection: RegionalSelection,
  ): void {
    const label = `${clientID}.${region}`;
    const catalogProviderID = providerSelection.catalogProvider
      ?? fail(`selection.providers.${label}.catalogProvider is required`);
    const catalogProvider = providers[catalogProviderID];
    if (!catalogProvider) fail(`selection provider ${label} references missing catalog provider ${catalogProviderID}`);
    const catalogModels = object(
      catalogProvider.models,
      `catalog.providers.${catalogProviderID}.models`,
    ) as Record<string, CatalogModel>;
    const selectedModelsForProvider = Array.isArray(providerSelection.models) && providerSelection.models.length > 0
      ? providerSelection.models
      : fail(`selection provider ${label} must include models`);
    const ids = new Set<string>();
    for (const selected of selectedModelsForProvider) {
      const sourceID = selected.source ?? fail(`selection provider ${label} has a model without source`);
      const model = catalogModels[sourceID];
      if (!model) fail(`selection provider ${label} references missing ${catalogProviderID}/${sourceID}`);
      const id = selected.id ?? model.id ?? sourceID;
      if (ids.has(id)) fail(`selection provider ${label} repeats model id ${id}`);
      ids.add(id);
      if (!model.name) fail(`${catalogProviderID}/${sourceID} has no name`);
      if (selected.displayName !== undefined && selected.displayName.trim().length === 0) {
        fail(`${label}/${id} displayName must not be empty`);
      }
      if (selected.providerModelID !== undefined && selected.providerModelID.trim().length === 0) {
        fail(`${label}/${id} providerModelID must not be empty`);
      }
      if (model.status && model.status !== "active") {
        fail(`${catalogProviderID}/${sourceID} has unsupported status ${model.status}`);
      }
      if (model.tool_call !== true) fail(`${catalogProviderID}/${sourceID} does not support tools`);
      if (typeof model.reasoning !== "boolean") fail(`${catalogProviderID}/${sourceID} has no reasoning capability`);
      if (!model.modalities?.input?.includes("text") || !model.modalities.output?.includes("text")) {
        fail(`${catalogProviderID}/${sourceID} must accept and produce text`);
      }
      const context = positiveInteger(model.limit?.context, `${catalogProviderID}/${sourceID} context limit`);
      const output = positiveInteger(model.limit?.output, `${catalogProviderID}/${sourceID} output limit`);
      if (selected.maxContext !== undefined) {
        const override = positiveInteger(selected.maxContext, `${label}/${id} maxContext`);
        if (override > context) fail(`${label}/${id} maxContext exceeds the catalog limit`);
      }
      if (selected.maxTokens !== undefined) {
        const override = positiveInteger(selected.maxTokens, `${label}/${id} maxTokens`);
        if (override > output) fail(`${label}/${id} maxTokens exceeds the catalog limit`);
      }
      if (selected.variant !== undefined && selected.variant !== "fast") {
        fail(`${label}/${id} uses unsupported variant ${selected.variant}`);
      }
      selectedModels += 1;
    }
  }

  return {
    canonicalModels: Object.keys(canonicalModels).length,
    providers: Object.keys(providers).length,
    providerModels,
    selectedModels,
  };
}

async function loadSelection(): Promise<SelectionFile> {
  return parse<SelectionFile>(await Bun.file(selectionPath).text(), "models-dev selection");
}

export async function validateBundledModelsDevCatalog(): Promise<CatalogSummary> {
  const catalogFile = Bun.file(catalogPath);
  if (!await catalogFile.exists()) fail(`missing ${catalogPath}; run bun run update:llms`);
  const [catalogText, selection] = await Promise.all([catalogFile.text(), loadSelection()]);
  return validate(parse<Catalog>(catalogText, "models.dev catalog"), selection);
}

async function update(): Promise<CatalogSummary> {
  const response = await fetch(source, { headers: { Accept: "application/json" } });
  if (!response.ok) fail(`${source} returned HTTP ${response.status}`);
  const text = await response.text();
  const selection = await loadSelection();
  const nextCatalog = parse<Catalog>(text, "models.dev catalog");
  const summary = validate(nextCatalog, selection);
  const catalogFile = Bun.file(catalogPath);
  const previousCatalog = await catalogFile.exists()
    ? parse<Catalog>(await catalogFile.text(), "bundled models.dev catalog")
    : undefined;
  reportDrift(previousCatalog ? catalogDrift(previousCatalog, nextCatalog, selection) : undefined);
  const temporaryPath = `${catalogPath}.${process.pid}.tmp`;
  try {
    await Bun.write(temporaryPath, text);
    await rename(temporaryPath, catalogPath);
  } finally {
    await unlink(temporaryPath).catch(() => undefined);
  }
  return summary;
}

function reportDrift(drift: CatalogDrift[] | undefined): void {
  if (!drift) {
    console.log("models.dev drift baseline unavailable");
    return;
  }
  if (drift.length === 0) {
    console.log("models.dev drift none");
    return;
  }
  for (const provider of drift) {
    console.log(`models.dev drift ${provider.providerID} clients=${provider.clients.join(",")}`);
    if (provider.addedCompatible.length > 0) {
      console.log(`  added-compatible: ${provider.addedCompatible.join(", ")}`);
    }
    if (provider.removedCompatible.length > 0) {
      console.log(`  removed-compatible: ${provider.removedCompatible.join(", ")}`);
    }
    if (provider.selectedChanges.length > 0) {
      console.log(`  selected-changed: ${provider.selectedChanges.join(", ")}`);
    }
  }
}

function report(mode: string, summary: CatalogSummary): void {
  console.log(
    `PASS models.dev ${mode} canonical=${summary.canonicalModels} providers=${summary.providers} providerModels=${summary.providerModels} selected=${summary.selectedModels}`,
  );
}

if (import.meta.main) {
  report("update", await update());
}

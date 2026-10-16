import { join } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";

const providersPath = join(ROOT, "apps/shared/Host/ModelProviders/providers.json");
const formats = new Set(["openai", "gemini", "chatgpt", "anthropic"]);
const ruleOptions = new Set(["serviceTier", "adaptiveThinking", "replayReasoning"]);

type Rule = { match?: unknown; exclude?: unknown; options?: Record<string, unknown>; outputTokens?: unknown };
type BundledProvider = {
  definition?: { id?: unknown };
  legacyID?: unknown;
  legacyCredentialID?: unknown;
  discovery?: { format?: unknown; catalog?: unknown; rules?: Rule[] };
};

function fail(message: string): never {
  throw new Error(message);
}

export async function check(): Promise<string> {
  const file = Bun.file(providersPath);
  if (!await file.exists()) fail(`missing ${providersPath}`);
  const providers = JSON.parse(await file.text()) as BundledProvider[];
  const ids = new Set<string>();
  let discovered = 0;
  for (const entry of providers) {
    const id = entry.definition?.id;
    if (typeof id !== "string" || ids.has(id)) fail(`providers.json has a missing or repeated id: ${String(id)}`);
    ids.add(id);
    if (typeof entry.legacyID !== "string" || typeof entry.legacyCredentialID !== "string") fail(`${id} needs legacy identifiers`);
    const discovery = entry.discovery;
    if (!discovery) continue;
    discovered += 1;
    if (!formats.has(String(discovery.format))) fail(`${id} uses unknown discovery format ${String(discovery.format)}`);
    if (discovery.catalog !== undefined && (typeof discovery.catalog !== "string" || discovery.catalog.length === 0)) fail(`${id} has an invalid catalog`);
    for (const rule of discovery.rules ?? []) {
      if (typeof rule.match !== "string" || rule.match.length === 0) fail(`${id} has a rule without match`);
      if (rule.exclude !== undefined && typeof rule.exclude !== "boolean") fail(`${id} has an invalid exclude rule`);
      if (rule.outputTokens !== undefined && !(Number.isInteger(rule.outputTokens) && Number(rule.outputTokens) > 0)) fail(`${id} has an invalid outputTokens rule`);
      for (const key of Object.keys(rule.options ?? {})) if (!ruleOptions.has(key)) fail(`${id} has an unsupported rule option ${key}`);
    }
  }
  return `providers=${ids.size} discovered=${discovered}`;
}

if (import.meta.main) await runCheck(check);

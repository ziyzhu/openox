import { requireHost } from "./host-request.ts";
import { type ProviderEntry } from "./host-snapshot.ts";
import { C, fail, terminalText, type CliContext } from "./lib.ts";

export async function providers(args: string[], context: CliContext): Promise<void> {
  const options = parseOptions(args);
  const result = await requireHost("providers.list", context, options.timeoutMs);
  const providers = Array.isArray(result.providers) ? result.providers as ProviderEntry[] : [];
  if (options.json) {
    console.log(JSON.stringify(providers, null, 2));
    return;
  }
  printProviders(providers);
}

function parseOptions(args: string[]): { timeoutMs: number; json: boolean } {
  let timeoutMs = 30000;
  let json = false;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--timeout") timeoutMs = positiveNumber(args[++index], "--timeout");
    else if (argument.startsWith("--timeout=")) timeoutMs = positiveNumber(argument.slice(10), "--timeout");
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox [--host <url>] host providers [--json] [--timeout 30000]");
      process.exit(0);
    } else fail(`unknown option: ${argument}`);
  }
  return { timeoutMs, json };
}

function printProviders(providers: ProviderEntry[]): void {
  if (!providers.length) {
    console.log("(no model providers)");
    return;
  }
  for (const provider of providers) {
    console.log(`${terminalText(provider.id, [C.sky])}  ${provider.displayName}  [${provider.regions.join(", ")}]`);
    for (const model of provider.models) {
      console.log(`  ${model.id}  ${model.displayName} · context ${model.maxContext.toLocaleString()} · maximum ${model.maxTokens.toLocaleString()}`);
    }
  }
}

function positiveNumber(value: string | undefined, flag: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) fail(`${flag} requires a positive number`);
  return parsed;
}

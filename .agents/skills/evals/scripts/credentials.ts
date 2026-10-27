import { join } from "node:path";
import { ROOT } from "../../../lib.ts";

const environment: Record<string, string> = { openai: "OPENAI_API_KEY", anthropic: "ANTHROPIC_API_KEY", gemini: "GEMINI_API_KEY" };
const secrets = new Set<string>();

export async function loadKeys(path = join(ROOT, "secrets/API_KEYS.json")): Promise<void> {
  for (const name of Object.values(environment)) if (process.env[name]) secrets.add(process.env[name]!);
  const file = Bun.file(path);
  if (!await file.exists()) return;
  let keys: unknown;
  try { keys = await file.json(); } catch { throw new Error("Invalid API_KEYS.json: expected a provider-key object"); }
  function visit(value: unknown, parts: string[]) {
    if (typeof value === "string") {
      if (value) secrets.add(value);
      const id = parts.join(":");
      const name = Object.hasOwn(environment, id) ? environment[id] : undefined;
      if (name && value && !process.env[name]) process.env[name] = value;
    } else if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const [name, child] of Object.entries(value)) visit(child, [...parts, name]);
    } else throw new Error("Invalid API_KEYS.json: expected nested provider names with string API keys");
  }
  if (!keys || typeof keys !== "object" || Array.isArray(keys)) throw new Error("Invalid API_KEYS.json: expected an object");
  visit(keys, []);
  for (const name of Object.values(environment)) if (process.env[name]) secrets.add(process.env[name]!);
}

export function redact(text: string): string {
  for (const secret of secrets) text = text.replaceAll(secret, "[REDACTED]");
  return text;
}

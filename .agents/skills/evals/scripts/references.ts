import type { EvalSnapshot } from "./types.ts";

export function at(value: unknown, path: string[]): unknown {
  for (const key of path) {
    if (!value || typeof value !== "object" || !Object.hasOwn(value, key)) return undefined;
    value = (value as Record<string, unknown>)[key];
  }
  return value;
}

export function actions(snapshot?: EvalSnapshot) {
  return (snapshot?.blocks ?? []).flatMap(block => block.kind.trace?.entries.flatMap(entry => entry.invocation ? [entry.invocation] : []) ?? []);
}

export function receiptValue(snapshot: EvalSnapshot | undefined, name: string, path: string[]): unknown {
  const matches = actions(snapshot).filter(call => call.name === name && "succeeded" in call.outcome);
  if (matches.length !== 1 || matches[0]!.preview?.resultTruncated) throw new Error(`Missing, ambiguous, or truncated receipt reference: ${name}`);
  const value = at(matches[0]!.outcome.succeeded?._0, path);
  if (value === undefined) throw new Error(`Missing receipt value: ${name}/${path.join("/")}`);
  return value;
}

export function resolveReferences(value: unknown, snapshot?: EvalSnapshot): unknown {
  if (Array.isArray(value)) return value.map(child => resolveReferences(child, snapshot));
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    if ("$receipt" in record) {
      if (typeof record.$receipt !== "string" || !Array.isArray(record.path) || !record.path.every(key => typeof key === "string") || Object.keys(record).some(key => !["$receipt", "path"].includes(key))) throw new Error("Invalid receipt reference");
      return receiptValue(snapshot, record.$receipt, record.path);
    }
    return Object.fromEntries(Object.entries(record).map(([key, child]) => [key, resolveReferences(child, snapshot)]));
  }
  return value;
}

export function receiptPrompt(text: string, snapshot?: EvalSnapshot): string {
  return text.replace(/\{\{receipt:(ox\.[A-Za-z.]+):([A-Za-z0-9_.]+)\}\}/g, (_, name: string, path: string) => {
    const value = receiptValue(snapshot, name, path.split("."));
    if (!["string", "number", "boolean"].includes(typeof value)) throw new Error("Prompt receipt references must be scalar values");
    return JSON.stringify(value);
  });
}

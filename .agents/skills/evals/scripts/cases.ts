import { readdir } from "node:fs/promises";
import { join } from "node:path";
import type { EvalCase } from "./types.ts";

const directory = join(import.meta.dir, "..", "cases");

export async function caseIds(): Promise<string[]> {
  return (await readdir(directory)).filter(name => name.endsWith(".ts")).map(name => name.slice(0, -3)).sort();
}

export async function loadCase(id: string): Promise<EvalCase> {
  if (!/^[a-z0-9-]+$/.test(id)) throw new Error(`Invalid case ID: ${id}`);
  const test = (await import(join(directory, `${id}.ts`))).default as EvalCase;
  if (typeof test?.task !== "string" || !test.task.trim() || typeof test.checks !== "function") throw new Error(`Case must default-export a task and checks: ${id}`);
  return test;
}

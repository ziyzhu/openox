import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { ROOT } from "../../../lib.ts";
import { SYSTEM_SKILL_NAMES } from "../../../../packages/protocol/src/skills.ts";
import { catalog } from "../../../../packages/agent/evals/stubs";
import type { EvalCase, Report } from "./types.ts";

export async function sourceFunctions(): Promise<string[]> {
  const directory = join(ROOT, "apps/shared/Host/VM/OxFunctions");
  const names = new Set<string>();
  for (const filename of await readdir(directory)) {
    if (!/^Ox.*\.swift$/.test(filename) || ["OxFunctionCatalog.swift", "OxFunctionBridge.swift"].includes(filename)) continue;
    const source = await readFile(join(directory, filename), "utf8");
    for (const match of source.matchAll(/"(ox\.[a-z]+(?:\.[A-Za-z]+)+)"/g)) names.add(match[1]!);
    if (filename === "OxFileSystem.swift") for (const match of source.matchAll(/__nativeFS\('([A-Za-z]+)'/g)) names.add(`ox.fs.${match[1]}`);
  }
  const browser = await readFile(join(ROOT, "apps/shared/Host/Services/Web/BrowserFunctionCatalog.swift"), "utf8");
  for (const match of browser.matchAll(/id: "([A-Za-z]+)"/g)) names.add(`ox.web.browser.${match[1]}`);
  return [...names].sort();
}

export async function validateCoverage(cases: EvalCase[]): Promise<void> {
  if (cases.length > 86) throw new Error("Catalog exceeds 86 scenarios; compose existing journeys before adding cases");
  const functions = await sourceFunctions();
  if (JSON.stringify(functions) !== JSON.stringify(Object.keys(catalog).sort())) throw new Error("Stub function catalog differs from native source; refresh and review contracts");
  const declared = [...new Set(cases.flatMap(coveredFunctions))].sort();
  if (JSON.stringify(functions) !== JSON.stringify(declared)) throw new Error(`Function coverage differs from source: missing ${functions.filter(name => !declared.includes(name)).join(", ")}; stale ${declared.filter(name => !functions.includes(name)).join(", ")}`);
  const skills = [...new Set(cases.flatMap(test => test.skill ? [test.skill] : []))].sort();
  if (JSON.stringify(skills) !== JSON.stringify([...SYSTEM_SKILL_NAMES].sort())) throw new Error("System skill workflow coverage differs from source");
  for (const path of new Set(cases.flatMap(test => test.resources ?? []))) {
    if (!(await readFile(join(ROOT, "packages/agent", path), "utf8")).trim()) throw new Error(`Missing required System skill resource: ${path}`);
  }
}

export function coverage(cases: EvalCase[], report?: Report) {
  return cases.map(test => {
    const attempts = report?.results.filter(result => result.id === test.id) ?? [];
    const status = !attempts.length ? "planned" : attempts.some(result => result.status === "error") ? "error"
      : attempts.some(result => result.status === "fail") ? "failed" : attempts.some(result => result.status === "blocked") ? "blocked"
      : attempts.length !== report?.limits.repetitions || attempts.some(result => result.status === "unverified") ? "unverified" : "passed";
    return { id: test.id, functions: coveredFunctions(test), skill: test.skill, variant: test.variant, status,
      fixture: attempts.some(result => result.fixture === "prepared") ? "prepared" : attempts.length ? "missing" : "unknown",
      attempts: attempts.length, executions: attempts.filter(result => result.response?.outcomes.length).length,
      reviews: attempts.filter(result => result.review.status !== "pending").length };
  });
}

export function coveredFunctions(test: EvalCase): string[] {
  return [...new Set([...(test.function ? [test.function] : []), ...(test.functions ?? [])])];
}

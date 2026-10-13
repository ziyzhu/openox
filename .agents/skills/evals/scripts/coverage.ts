import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { ROOT } from "../../../lib.ts";
import { SYSTEM_SKILL_NAMES } from "../../../../packages/protocol/src/skills.ts";
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
  const functions = await sourceFunctions();
  const declared = [...new Set(cases.flatMap(test => test.function ? [test.function] : []))].sort();
  if (JSON.stringify(functions) !== JSON.stringify(declared)) throw new Error(`Function coverage differs from source: missing ${functions.filter(name => !declared.includes(name)).join(", ")}; stale ${declared.filter(name => !functions.includes(name)).join(", ")}`);
  for (const name of functions) for (const variant of ["success", "failure", "boundary"]) {
    if (!cases.some(test => test.function === name && test.variant === variant)) throw new Error(`Missing ${variant} coverage: ${name}`);
  }
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
    return { id: test.id, function: test.function, skill: test.skill, variant: test.variant, status,
      fixture: attempts.some(result => result.fixture === "prepared") ? "prepared" : attempts.length ? "missing" : "unknown",
      attempts: attempts.length, executions: attempts.filter(result => result.response?.outcomes.length).length,
      reviews: attempts.filter(result => result.review.status !== "pending").length };
  });
}

import { createHash } from "node:crypto";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { parseArgs } from "node:util";
import { ROOT as root } from "../../../lib.ts";
import { cases, smokeIds } from "./cases/index.ts";
import { score } from "./scoring.ts";
import { coverage, coveredFunctions, validateCoverage } from "./coverage.ts";
import { fixtureTemplate, validateFixture } from "./fixtures.ts";
import type { EvalCase, Fixture, Report } from "./types.ts";
import { compare } from "./compare.ts";
import { EvalRuntime, evalModels } from "../../../../packages/agent/evals/runtime";
import { catalog, Stubs } from "../../../../packages/agent/evals/stubs";
import { runCase } from "./ox.ts";

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => [key, canonical(child)]));
  return value;
}
export const hash = (value: unknown): string => createHash("sha256").update(JSON.stringify(canonical(value))).digest("hex");

function integer(value: string, minimum: number, maximum: number): number {
  const number = Number(value);
  if (!Number.isInteger(number) || number < minimum || number > maximum) throw new Error(`Expected an integer ${minimum}..${maximum}: ${value}`);
  return number;
}

export async function validateCases(tests: EvalCase[]): Promise<void> {
  const ids = new Set<string>();
  for (const test of tests) {
    if (!/^[a-z0-9-]+$/.test(test.id) || ids.has(test.id)) throw new Error(`Invalid or duplicate case ID: ${test.id}`);
    ids.add(test.id);
    if (!["functions", "workflows", "safety"].includes(test.suite) || !["success", "failure", "boundary"].includes(test.variant)
      || !["read", "profile", "installation", "external"].includes(test.effect) || !test.task.includes("{{context}}") || !test.rubric.trim()
      || !test.evidence.outcome || !test.evidence.preserved || test.effect !== "read" && !test.evidence.cleanup
      || test.variant !== "success" && !test.evidence.condition) throw new Error(`Incomplete scenario contract: ${test.id}`);
    if (test.choice && (JSON.stringify(test.choice.options) !== JSON.stringify(["Create skill", "Revise proposal", "Cancel"])
      || !test.choice.options.includes(test.choice.answer) || test.skill !== "evolve")) throw new Error(`Unsupported automatic workflow choice: ${test.id}`);
    if (test.probe && (!test.evidence.probe || test.probe.includes("{{context}}"))) throw new Error(`Probe must use independent inputs: ${test.id}`);
    if (test.resources?.some(path => !test.skill || !path.startsWith(`skills/${test.skill}/references/`) || path.includes(".."))) throw new Error(`Invalid required skill resource: ${test.id}`);
  }
  await validateCoverage(tests);
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", ...args], { cwd: root });
  if (result.exitCode !== 0) throw new Error("Cannot determine repository revision");
  return result.stdout.toString().trim();
}

async function outsideRepository(path: string): Promise<string> {
  const output = resolve(path);
  const lexical = relative(root, output);
  if (!lexical.startsWith("../") && !isAbsolute(lexical)) throw new Error("Keep QA fixtures and evidence outside the repository");
  await mkdir(dirname(output), { recursive: true });
  const directory = await realpath(dirname(output));
  const fromRoot = relative(await realpath(root), directory);
  if (fromRoot !== ".." && !fromRoot.startsWith("../") && !isAbsolute(fromRoot)) throw new Error("Keep QA fixtures and evidence outside the repository");
  return resolve(directory, output.split("/").at(-1)!);
}

async function readReport(path: string): Promise<Report> {
  const report: Report = await Bun.file(path).json();
  compare(report, report);
  return report;
}

async function main(): Promise<void> {
  if (Bun.argv[2] === "compare") {
    if (Bun.argv.length !== 5) throw new Error("Usage: bun run evals compare <baseline> <candidate>");
    const differences = compare(await readReport(Bun.argv[3]!), await readReport(Bun.argv[4]!));
    console.log(JSON.stringify(differences, null, 2));
    process.exitCode = differences.some(result => result.change === "not-comparable") ? 2 : differences.some(result => result.change === "regression") ? 1 : 0;
    return;
  }
  const { values } = parseArgs({ args: Bun.argv.slice(2), options: {
    help: { type: "boolean" }, list: { type: "boolean" }, validate: { type: "boolean" }, json: { type: "boolean" }, template: { type: "boolean" },
    coverage: { type: "string" }, review: { type: "string" }, decision: { type: "string" }, note: { type: "string" }, repetition: { type: "string", default: "1" },
    provider: { type: "string" }, model: { type: "string" }, fixture: { type: "string" },
    suite: { type: "string", default: "smoke" }, case: { type: "string" }, repeat: { type: "string", default: "1" },
    timeout: { type: "string" }, output: { type: "string" },
    "qa-profile": { type: "string" },
  }, strict: true });
  if (values.help) {
    console.log(`Usage: bun run evals --fixture <outside-repo.json> --provider <id> --model <id> [options]
  --suite smoke|functions|workflows|safety|all (default smoke)
  --case <id> --repeat <1..20> --timeout <1..300000 ms>
  --list [--json] | --validate | --template --qa-profile <name>
  --coverage <report.json>       Show planned, blocked, failed, unverified and passed coverage
  --review <report.json> --case <id> --repetition <n> --decision pass|fail --note <evidence> --output <new-report>
  --qa-profile <name>           Synthetic Profile name matching the fixture
  Providers: openai, anthropic, google (standard API-key environment variables)
  --output <new-outside-path>   Owner-only report; never overwrite evidence
  compare <baseline.json> <candidate.json>
Missing fixtures/preconditions are blocked. Successful automatic checks remain unverified until manual rubric review.
Real model and production agent loop; isolated stateful ox stubs. No Host or simulator. VM integration tests are separate.`);
    return;
  }
  await validateCases(cases);
  if (values.coverage) {
    console.log(JSON.stringify(coverage(cases, await readReport(values.coverage)), null, 2));
    return;
  }
  if (values.review) {
    if (!values.case || !values.note?.trim() || !["pass", "fail"].includes(values.decision ?? "") || !values.output) throw new Error("Review requires --case, --decision pass|fail, --note, and --output <new-report>");
    const report = await readReport(values.review);
    const result = report.results.find(entry => entry.id === values.case && entry.repetition === integer(values.repetition!, 1, 20));
    if (!result || !["pass", "unverified", "fail"].includes(result.status)) throw new Error("Cannot review missing, blocked, or errored evidence");
    if (values.decision === "pass" && (!result.checks.length || result.checks.some(check => !check.passed) || result.response?.errors.length || result.response?.blocked || !result.contextHash)) throw new Error("Manual review cannot override failed or missing automatic evidence");
    result.review = { status: values.decision as "pass" | "fail", note: values.note.trim() };
    result.status = values.decision as "pass" | "fail";
    await writeFile(await outsideRepository(values.output), JSON.stringify(report, null, 2), { flag: "wx", mode: 0o600 });
    console.log(`Recorded ${values.decision} review for ${result.id}, repetition ${result.repetition}`);
    return;
  }
  if (!["smoke", "functions", "workflows", "safety", "all"].includes(values.suite!)) throw new Error(`Unknown suite: ${values.suite}`);
  const selected = cases.filter(test => values.case ? test.id === values.case : values.suite === "smoke" ? smokeIds.has(test.id) : values.suite === "all" || test.suite === values.suite);
  if (!selected.length) throw new Error("No matching eval cases");
  if (values.template) {
    const template = fixtureTemplate(selected, values["qa-profile"] ?? "");
    if (values.output) await writeFile(await outsideRepository(values.output), JSON.stringify(template, null, 2), { flag: "wx", mode: 0o600 });
    else console.log(JSON.stringify(template, null, 2));
    return;
  }
  if (values.list || values.validate) {
    if (values.json) console.log(JSON.stringify(selected, null, 2));
    else {
      if (values.list) for (const test of selected) console.log(`${test.id}\t${test.suite}\t${test.effect}\t${test.description}`);
      console.log(`Validated ${cases.length} scenarios covering ${new Set(cases.flatMap(coveredFunctions)).size} functions and ${new Set(cases.flatMap(test => test.skill ? [test.skill] : [])).size} System skills`);
    }
    if (values.fixture) {
      const fixture = validateFixture(await Bun.file(values.fixture).json());
      for (const binding of Object.values(fixture.cases)) new Stubs(binding.stubs ?? {}, fixture.qaProfile);
    }
    return;
  }
  if (!values.fixture || !values.provider || !values.model || !values["qa-profile"]?.trim()) throw new Error("Specify --fixture, --provider, --model, and --qa-profile for an isolated stub evaluation");
  if (values.provider.toLowerCase() === "mock") throw new Error("Mock cannot establish real-model quality");
  const fixturePath = await realpath(values.fixture);
  await outsideRepository(fixturePath);
  const fixture: Fixture = validateFixture(await Bun.file(fixturePath).json());
  if (fixture.qaProfile !== values["qa-profile"]) throw new Error("Fixture and requested QA Profile differ");
  const repetitions = integer(values.repeat!, 1, 20);
  const timeoutMs = integer(values.timeout ?? (values.suite === "smoke" ? "30000" : "120000"), 1, 300_000);
  const output = await outsideRepository(values.output ?? resolve(tmpdir(), `ox-evals-${Date.now()}.json`));
  await writeFile(output, "", { flag: "wx", mode: 0o600 });
  const report: Report = {
    version: 4, startedAt: new Date().toISOString(), revision: git("rev-parse", "HEAD"), dirty: git("status", "--porcelain").length > 0,
    limits: { timeoutMs, repetitions }, authorization: { profileWrites: false, installationWrites: false, externalEffects: false, choices: true, qaProfile: fixture.qaProfile },
    fixtureHash: hash({ fixture, catalog }), host: null, provider: values.provider, model: values.model, catalog: null, mode: "stubbed-ox", plannedCases: selected.map(test => test.id), results: [],
  };
  const models = evalModels(values.provider);
  report.catalog = { functions: catalog };
  const blocked = (test: EvalCase) => fixture.cases[test.id] ? undefined : "Stub fixture not prepared";
  try {
    let stop = false;
    for (const test of selected) {
      for (let repetition = 1; repetition <= repetitions; repetition++) {
        const binding = fixture.cases[test.id];
        const base = { id: test.id, fixture: binding ? "prepared" as const : "missing" as const, caseHash: hash({ test, binding }), repetition, rubric: test.rubric, review: { status: "pending" as const } };
        const reason = blocked(test);
        if (reason) {
          report.results.push({ ...base, status: "blocked", checks: [], error: reason });
          console.log(`BLOCKED ${test.id}: ${reason}`);
          continue;
        }
        try {
          const runtime = await EvalRuntime.open(values.provider, values.model, binding!.stubs ?? {}, fixture.qaProfile, models);
          let response;
          try { response = await runCase(runtime, values.provider, values.model, test, binding!, timeoutMs, { qaProfile: fixture.qaProfile, choices: true, humanWaitMs: 0 }); }
          finally { await runtime.close(); }
          const checks = response.snapshot ? score(test, binding!, response) : response.observationChecks;
          const status = response.errors.length ? "error" : response.blocked ? "blocked" : checks.length && checks.every(check => check.passed) ? "unverified" : "fail";
          const initial = response.initial;
          const contextHash = initial ? hash({ systemPrompt: initial.systemPrompt, renderedSystemPrompt: initial.renderedSystemPrompt, soul: initial.soul, memory: initial.memory, tools: initial.tools, model: initial.model, systemSkill: response.systemSkill }) : undefined;
          report.results.push({ ...base, status, checks, contextHash, response });
          console.log(`${status.toUpperCase()} ${test.id} ${repetition}/${repetitions}`);
          for (const check of checks.filter(check => !check.passed)) console.log(`  ${check.detail}`);
          for (const error of response.errors) console.log(`  ${error}`);
          stop = response.continuation === "stop";
        } catch (error) {
          report.results.push({ ...base, status: "error", checks: [], error: String(error) });
          stop = true;
        }
        await writeFile(output, JSON.stringify(report, null, 2), { mode: 0o600 });
        if (stop) break;
      }
      if (stop) break;
    }
    process.exitCode = report.results.some(result => ["fail", "error"].includes(result.status)) ? 1 : report.results.some(result => result.status !== "pass") || report.results.length < selected.length * repetitions ? 2 : 0;
  } finally {
    await writeFile(output, JSON.stringify(report, null, 2), { mode: 0o600 });
    console.log(`Report: ${output}`);
  }
}

if (import.meta.main) await main().catch(error => { console.error(error.message); process.exitCode = 1; });

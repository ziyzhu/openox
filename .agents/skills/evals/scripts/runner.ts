import { createHash } from "node:crypto";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { parseArgs } from "node:util";
import { ROOT as root } from "../../../lib.ts";
import { cases } from "./cases/index.ts";
import { score } from "./scoring.ts";
import type { EvalCase, EvalSnapshot, Report } from "./types.ts";
import { compare } from "./compare.ts";
import { ox } from "./cli.ts";
import { runCase } from "./ox.ts";

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => [key, canonical(child)]));
  return value;
}

export const hash = (value: unknown): string => createHash("sha256").update(JSON.stringify(canonical(value))).digest("hex");

function integer(value: string, maximum: number): number {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1 || number > maximum) throw new Error(`Expected an integer from 1 to ${maximum}: ${value}`);
  return number;
}

export function validateCases(tests: EvalCase[]): void {
  const ids = new Set<string>();
  for (const test of tests) {
    if (!/^[a-z0-9-]+$/.test(test.id) || ids.has(test.id)) throw new Error(`Invalid or duplicate case ID: ${test.id}`);
    ids.add(test.id);
    if (!test.prompts.length || test.prompts.length > 10 || !test.prompts.every(prompt => prompt.trim()) || !test.rules.length || !test.rubric.trim()) throw new Error(`Incomplete case: ${test.id}`);
    if (!["quick", "tasks", "workflows"].includes(test.suite)) throw new Error(`Invalid suite: ${test.id}`);
    if ((test.suite === "workflows") !== (test.workflow?.kind === "createSkill")) throw new Error(`Invalid workflow authorization: ${test.id}`);
    if (test.workflow?.kind === "createSkill" && (!test.workflow.description.trim() || !test.workflow.instructions.trim() || !test.workflow.probe.trim() || test.workflow.probe.includes("{{answer}}"))) throw new Error(`Invalid independent probe: ${test.id}`);
    for (const rule of test.rules) {
      if (rule.kind === "actionAtLeast" && (!rule.name || !Number.isInteger(rule.count) || rule.count < 0)) throw new Error(`Invalid call rule: ${test.id}`);
      if (rule.kind === "readsGuidance" && (!/^guidance\/[a-z-]+\/guide\.md$/.test(rule.path) || test.workflow?.kind !== "guidance" || test.workflow.path !== rule.path)) throw new Error(`Invalid guidance observation: ${test.id}`);
      if (rule.kind === "skillWorks" && test.workflow?.kind !== "createSkill") throw new Error(`Missing skill workflow: ${test.id}`);
    }
  }
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", ...args], { cwd: root });
  if (result.exitCode !== 0) throw new Error("Cannot determine repository revision");
  return result.stdout.toString().trim();
}

async function outputPath(path: string): Promise<string> {
  const output = resolve(path);
  const lexical = relative(root, output);
  if (!lexical.startsWith("../") && !isAbsolute(lexical)) throw new Error("Store eval reports outside the repository");
  await mkdir(dirname(output), { recursive: true });
  const directory = await realpath(dirname(output));
  const fromRoot = relative(await realpath(root), directory);
  if (!fromRoot || (!fromRoot.startsWith("../") && !isAbsolute(fromRoot))) throw new Error("Store eval reports outside the repository");
  return resolve(directory, output.split("/").at(-1)!);
}

async function main(): Promise<void> {
  if (Bun.argv[2] === "compare") {
    if (Bun.argv.length !== 5) throw new Error("Usage: bun run evals compare <baseline.json> <candidate.json>");
    const differences = compare(await Bun.file(Bun.argv[3]!).json(), await Bun.file(Bun.argv[4]!).json());
    console.log(JSON.stringify(differences, null, 2));
    if (differences.some(result => result.change === "not-comparable")) process.exitCode = 2;
    else if (differences.some(result => result.change === "regression")) process.exitCode = 1;
    return;
  }
  const { values } = parseArgs({ args: Bun.argv.slice(2), options: {
    help: { type: "boolean" }, list: { type: "boolean" }, validate: { type: "boolean" },
    host: { type: "string" }, provider: { type: "string" }, model: { type: "string" },
    suite: { type: "string", default: "quick" }, case: { type: "string" }, repeat: { type: "string", default: "1" },
    timeout: { type: "string", default: "120000" }, output: { type: "string" },
    "allow-profile-writes": { type: "boolean" }, "qa-profile": { type: "string" },
  }, strict: true });
  if (values.help) {
    console.log(`Usage: bun run evals --host <ws-url> --provider <id> --model <id> [options]
  --suite quick|tasks|workflows|all   Default: quick
  --allow-profile-writes   Authorize run-owned skill creation and cleanup
  --qa-profile <name>      Required named local QA Profile for workflows
  --case <id>        Run one case instead of a suite
  --repeat <1..20>   Repetitions per case (default 1)
  --timeout <ms>    Per-case chat deadline, at most 300000 (default 120000)
  --output <path>   New JSON report outside the repo (default temporary directory)
  --list            List selected cases without contacting a provider
  --validate        Check case definitions without contacting a provider
  compare <baseline.json> <candidate.json>

Drives ordinary chats through this checkout's Ox CLI and scores history plus independent state.
Workflows use saved task chats and fresh probes; observers never repair results.
Captures Host logs for diagnosis. Tools execute normally; use a sanitized QA Profile.
Never approves prompts. Stops its chat on timeout and does not retry submitted input.`);
    return;
  }
  validateCases(cases);
  if (!["quick", "tasks", "workflows", "all"].includes(values.suite!)) throw new Error(`Unknown suite: ${values.suite}`);
  const selected = cases.filter(test => values.case ? test.id === values.case : values.suite === "all" || test.suite === values.suite);
  if (!selected.length) throw new Error("No matching eval cases");
  if (values.list || values.validate) {
    for (const test of selected) console.log(`${test.id}\t${test.suite}\t${test.description}`);
    console.log(`Validated ${cases.length} cases`);
    return;
  }
  const writes = selected.some(test => test.workflow?.kind === "createSkill");
  if (writes && (!values["allow-profile-writes"] || !values["qa-profile"]?.trim())) throw new Error("Workflows require --allow-profile-writes and --qa-profile <local-QA-name>");
  if (!values.host || !values.provider || !values.model) throw new Error("Specify --host, --provider, and --model; use ox host list and ox host providers to select them");
  if (values.provider.toLowerCase() === "mock") throw new Error("Mock responses cannot measure prompt quality");
  const repetitions = integer(values.repeat!, 20);
  const timeoutMs = integer(values.timeout!, 300_000);
  const output = await outputPath(values.output ?? resolve(tmpdir(), `ox-evals-${Date.now()}.json`));
  await writeFile(output, "", { flag: "wx", mode: 0o600 });
  const host = values.host;
  const report: Report = {
    version: 3, startedAt: new Date().toISOString(), revision: git("rev-parse", "HEAD"), dirty: git("status", "--porcelain").length > 0,
    limits: { timeoutMs, repetitions }, authorization: { profileWrites: !!values["allow-profile-writes"], qaProfile: values["qa-profile"] ?? null }, host: null, provider: values.provider, model: values.model, catalog: null, mode: "ox-cli-chat", plannedCases: selected.map(test => test.id), results: [],
  };
  try {
    const description = await ox<{ implementation: unknown; methods: string[] }>(host, ["host", "describe"]);
    const methods = ["chats.new", "chats.send", "chats.get", "chats.stop", "logs.list", ...(selected.some(test => test.workflow) ? ["vm.call"] : []), ...(writes ? ["chats.open"] : [])];
    if (!methods.every(method => description.methods.includes(method))) throw new Error("Host lacks required chat/log commands; update Ox");
    report.host = description.implementation;
    const providers = await ox<Array<{ id: string; models: Array<{ id: string }> }>>(host, ["host", "providers"]);
    const provider = providers.find(entry => entry.id === values.provider);
    const model = provider?.models.find(entry => entry.id === values.model);
    if (!model) throw new Error("Requested provider/model is not exposed by this Host");
    report.catalog = { provider, model };
    const active = await ox<EvalSnapshot | null>(host, ["chat", "inspect"]);
    if (active?.isBusy || active?.pendingPrompt) throw new Error("QA Host has a running chat or pending prompt; leave it untouched");
    for (const test of selected) {
      for (let repetition = 1; repetition <= repetitions; repetition++) {
        const base = { id: test.id, caseHash: hash(test), repetition, rubric: test.rubric };
        try {
          const response = await runCase(host, values.provider, values.model, test, timeoutMs, values["qa-profile"]);
          const checks = score(test, response);
          const status = response.errors.length || response.outcomes.some(turn => ["failed", "cancelled"].includes(turn.outcome)) ? "error" : checks.every(check => check.passed) ? "pass" : "fail";
          const initial = response.initial;
          const contextHash = initial ? hash({ systemPrompt: initial.systemPrompt, renderedSystemPrompt: initial.renderedSystemPrompt, soul: initial.soul, memory: initial.memory, tools: initial.tools, model: initial.model }) : undefined;
          report.results.push({ ...base, status, checks, contextHash, response });
          console.log(`${status.toUpperCase()} ${test.id} ${repetition}/${repetitions}`);
          for (const check of checks.filter(check => !check.passed)) console.log(`  ${check.detail}`);
          for (const error of response.errors) console.log(`  ${error}`);
        } catch (error) {
          report.results.push({ ...base, status: "error", checks: [], error: error instanceof Error ? error.message : String(error) });
          console.log(`ERROR ${test.id}; see report`);
          break;
        } finally {
          await writeFile(output, JSON.stringify(report, null, 2), { mode: 0o600 });
        }
        if (report.results.at(-1)?.status === "error" || report.results.at(-1)?.response?.continuation === "stop") break;
      }
      if (report.results.at(-1)?.status === "error" || report.results.at(-1)?.response?.continuation === "stop") break;
    }
    if (report.results.some(result => result.status !== "pass")) process.exitCode = 1;
  } finally {
    await writeFile(output, JSON.stringify(report, null, 2), { mode: 0o600 });
    console.log(`Report: ${output}`);
  }
}

if (import.meta.main) await main().catch(error => { console.error(error.message); process.exitCode = 1; });

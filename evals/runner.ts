import { createHash } from "node:crypto";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { parseArgs } from "node:util";
import { HostRPCClient } from "../apps/cli/src/host-rpc.ts";
import { cases } from "./cases/index.ts";
import { score } from "./scoring.ts";
import type { EvalCase, EvalResponse, Report } from "./types.ts";
import { compare } from "./compare.ts";

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => [key, canonical(child)]));
  return value;
}

export const hash = (value: unknown): string => createHash("sha256").update(JSON.stringify(canonical(value))).digest("hex");
const root = resolve(import.meta.dir, "..");

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
    for (const fixture of test.fixtures) {
      if (fixture.tool !== "execute" || fixture.sourceIncludes.length === 0) throw new Error(`Unconstrained fixture: ${test.id}`);
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
    host: { type: "string" }, chat: { type: "string" }, provider: { type: "string" }, model: { type: "string" },
    suite: { type: "string", default: "quick" }, case: { type: "string" }, repeat: { type: "string", default: "1" },
    timeout: { type: "string", default: "120000" }, "max-turns": { type: "string", default: "6" }, output: { type: "string" },
  }, strict: true });
  if (values.help) {
    console.log(`Usage: bun run evals --host <ws-url> --provider <id> --model <id> [options]
  --chat <id>        Empty chat whose prompt and tools are used (defaults to active)
  --suite quick|tasks|all   Default: quick
  --case <id>        Run one case instead of a suite
  --repeat <1..20>   Repetitions per case (default 1)
  --timeout <ms>    Per-case Host deadline, at most 300000 (default 120000)
  --max-turns <1..20>  Model-turn budget per case (default 6)
  --output <path>   New JSON report outside the repo (default temporary directory)
  --list            List selected cases without contacting a provider
  --validate        Check case definitions without contacting a provider
  compare <baseline.json> <candidate.json>

Runs real models with the production Agent loop and fixture-backed tools.
Requires a running simulator Host built from this checkout; never executes generated JavaScript.`);
    return;
  }
  validateCases(cases);
  if (!["quick", "tasks", "all"].includes(values.suite!)) throw new Error(`Unknown suite: ${values.suite}`);
  const selected = cases.filter(test => values.case ? test.id === values.case : values.suite === "all" || test.suite === values.suite);
  if (!selected.length) throw new Error("No matching eval cases");
  if (values.list || values.validate) {
    for (const test of selected) console.log(`${test.id}\t${test.suite}\t${test.description}`);
    console.log(`Validated ${cases.length} cases`);
    return;
  }
  if (!values.host || !values.provider || !values.model) throw new Error("Specify --host, --provider, and --model; use ox discover and ox agent list to select them");
  if (values.provider.toLowerCase() === "mock") throw new Error("Mock responses cannot measure prompt quality");
  const repetitions = integer(values.repeat!, 20);
  const timeoutMs = integer(values.timeout!, 300_000);
  const maxTurns = integer(values["max-turns"]!, 20);
  const output = await outputPath(values.output ?? resolve(tmpdir(), `ox-evals-${Date.now()}.json`));
  await writeFile(output, "", { flag: "wx", mode: 0o600 });
  const host = new HostRPCClient(values.host);
  const report: Report = {
    version: 1, startedAt: new Date().toISOString(), revision: git("rev-parse", "HEAD"), dirty: git("status", "--porcelain").length > 0,
    limits: { timeoutMs, maxTurns, repetitions }, host: null, provider: values.provider, model: values.model, catalog: null, mode: "production-agent-fixture-tools", results: [],
  };
  try {
    const description = await host.describe(10000);
    if (!description.methods.includes("agents.evaluate")) throw new Error("Host does not support agents.evaluate; rebuild and install this checkout");
    report.host = description.implementation;
    const catalog = await host.call("models.list", 10000);
    const clients = catalog.clients as Array<{ id: string; models: Array<{ id: string }> }>;
    const client = clients.find(entry => entry.id === values.provider);
    const model = client?.models.find(entry => entry.id === values.model);
    if (!model) throw new Error("Requested provider/model is not exposed by this Host");
    report.catalog = { region: catalog.region, model };
    const snapshot = await host.call("chats.get", 10000, values.chat ? { sessionId: values.chat } : {});
    const template = snapshot.data as { id?: string; messages?: unknown[] } | null;
    if (!template?.id || !Array.isArray(template.messages) || template.messages.length) throw new Error("Open a fresh empty chat before running evals");
    for (const test of selected) {
      for (let repetition = 1; repetition <= repetitions; repetition++) {
        const base = { id: test.id, caseHash: hash(test), repetition, rubric: test.rubric };
        try {
          const response = await host.call("agents.evaluate", timeoutMs + 10000, {
            sessionId: template.id, clientId: values.provider, modelId: values.model,
            prompts: test.prompts, fixtures: test.fixtures, maxTurns, timeoutMs,
          }) as unknown as EvalResponse;
          if (!Array.isArray(response.messages) || !Array.isArray(response.errors) || typeof response.systemPrompt !== "string") throw new Error("Invalid eval response");
          const checks = score(test, response);
          const status = response.executionError ? "error" : checks.every(check => check.passed) ? "pass" : "fail";
          report.results.push({ ...base, status, checks, contextHash: hash({ systemPrompt: response.systemPrompt, tools: response.tools, temperature: response.temperature, maxTokens: response.maxTokens }), response });
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
        if (report.results.at(-1)?.status === "error") break;
      }
      if (report.results.at(-1)?.status === "error") break;
    }
    if (report.results.some(result => result.status !== "pass")) process.exitCode = 1;
  } finally {
    host.close();
    await writeFile(output, JSON.stringify(report, null, 2), { mode: 0o600 });
    console.log(`Report: ${output}`);
  }
}

if (import.meta.main) await main().catch(error => { console.error(error.message); process.exitCode = 1; });

import { existsSync } from "node:fs";
import { cp, mkdir, mkdtemp, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import { parseArgs } from "node:util";
import { ROOT } from "../../../lib.ts";
import { Stubs } from "../../../../packages/agent/evals/stubs";
import { caseIds, loadCase } from "./cases.ts";
import { validateCatalog } from "./catalog.ts";
import { summarize } from "./report.ts";
import type { Outcome, RunRecord } from "./types.ts";

type Variant = { name: string; root: string; revision: string; dirty: boolean; ref?: string };
type Task = { id: string; variant: Variant; repetition: number };

const usage = `Usage: bun run evals --provider <id> --model <id> [options]
  --baseline <ref>       Also run each case against the prompts at this git ref
  --case <id>            Run only this case; repeatable (default: all cases)
  --repeat <1..20>       Runs per case and variant (default 1)
  --timeout <ms>         Override each case's limit (default: case timeoutMs or 120000)
  --jobs <n>             Concurrent runs (default 4)
  --output <dir>         New report directory outside the repository (default: temporary)
  --list | --validate
Providers: openai, anthropic, google (standard API-key environment variables).
Real model and production agent loop with isolated stateful ox stubs. No Host or simulator.`;

function integer(value: string, minimum: number, maximum: number): number {
  const number = Number(value);
  if (!Number.isInteger(number) || number < minimum || number > maximum) throw new Error(`Expected an integer ${minimum}..${maximum}: ${value}`);
  return number;
}

function git(root: string, ...args: string[]): string {
  const result = Bun.spawnSync(["git", ...args], { cwd: root });
  if (result.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.stderr.toString().trim()}`);
  return result.stdout.toString().trim();
}

async function outputDirectory(path?: string): Promise<string> {
  if (!path) return mkdtemp(join(tmpdir(), "ox-evals-"));
  const directory = resolve(path);
  const fromRoot = relative(ROOT, directory);
  if (!fromRoot.startsWith("..") && !isAbsolute(fromRoot)) throw new Error("Keep eval reports outside the repository");
  await mkdir(directory);
  return directory;
}

async function baseline(ref: string): Promise<Variant> {
  const revision = git(ROOT, "rev-parse", "--verify", `${ref}^{commit}`);
  const root = await mkdtemp(join(tmpdir(), "ox-evals-baseline-"));
  git(ROOT, "worktree", "add", "--detach", root, revision);
  try {
    for (const path of [".agents/skills/evals", "packages/agent/evals"]) {
      await rm(join(root, path), { recursive: true, force: true });
      await cp(join(ROOT, path), join(root, path), { recursive: true });
    }
    const workspaces = ["", ...(await Promise.all(["apps", "packages"].map(async parent => (await readdir(join(ROOT, parent))).map(name => join(parent, name))))).flat()];
    for (const workspace of workspaces) {
      if (existsSync(join(ROOT, workspace, "node_modules")) && existsSync(join(root, workspace))) await symlink(join(ROOT, workspace, "node_modules"), join(root, workspace, "node_modules"));
    }
  } catch (error) { git(ROOT, "worktree", "remove", "--force", root); throw error; }
  return { name: "baseline", root, revision, dirty: false, ref };
}

async function arm(task: Task, provider: string, model: string, timeout: string, directory: string): Promise<RunRecord> {
  const name = `${task.id}.${task.variant.name}.${task.repetition}`;
  const output = join(directory, "runs", `${name}.json`);
  const child = Bun.spawn([process.execPath, join(task.variant.root, ".agents/skills/evals/scripts/arm.ts"), task.id, provider, model, timeout, output], { cwd: task.variant.root, stdout: "ignore", stderr: "pipe" });
  const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  const base = { case: task.id, variant: task.variant.name, repetition: task.repetition };
  if (code !== 0 || !await Bun.file(output).exists()) return { ...base, status: "error", checks: [], error: stderr.trim() || `arm exited ${code}` };
  const { turn: _turn, ...outcome } = await Bun.file(output).json() as Outcome & { turn?: unknown };
  return { ...base, ...outcome, transcript: output };
}

async function pool<T, R>(items: T[], jobs: number, work: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(jobs, items.length) }, async () => {
    while (next < items.length) { const index = next++; results[index] = await work(items[index]!); }
  }));
  return results;
}

async function main(): Promise<void> {
  const { values } = parseArgs({ args: Bun.argv.slice(2), options: {
    help: { type: "boolean" }, list: { type: "boolean" }, validate: { type: "boolean" },
    provider: { type: "string" }, model: { type: "string" }, case: { type: "string", multiple: true },
    baseline: { type: "string" }, repeat: { type: "string", default: "1" }, timeout: { type: "string" }, jobs: { type: "string", default: "4" }, output: { type: "string" },
  }, strict: true });
  if (values.help) return console.log(usage);
  const ids = await caseIds();
  if (values.list) return console.log(ids.join("\n"));
  if (values.validate) {
    for (const id of ids) new Stubs((await loadCase(id)).stubs ?? {});
    return console.log(`Validated ${ids.length} cases; stub catalog matches ${await validateCatalog()} native functions`);
  }
  if (!values.provider || !values.model) throw new Error(usage);
  const selected = values.case ?? ids;
  for (const id of selected) if (!ids.includes(id)) throw new Error(`Unknown case: ${id}`);
  const repetitions = integer(values.repeat!, 1, 20);
  const timeout = values.timeout ? String(integer(values.timeout, 1, 600_000)) : "default";
  const directory = await outputDirectory(values.output);
  const candidate: Variant = { name: "candidate", root: ROOT, revision: git(ROOT, "rev-parse", "HEAD"), dirty: git(ROOT, "status", "--porcelain").length > 0 };
  const variants = values.baseline ? [await baseline(values.baseline), candidate] : [candidate];
  try { await evaluateVariants(variants, selected, { provider: values.provider, model: values.model, repetitions, timeout, jobs: integer(values.jobs!, 1, 16), directory }); }
  finally { if (values.baseline) git(ROOT, "worktree", "remove", "--force", variants[0]!.root); }
}

type Options = { provider: string; model: string; repetitions: number; timeout: string; jobs: number; directory: string };

async function evaluateVariants(variants: Variant[], selected: string[], { provider, model, repetitions, timeout, jobs, directory }: Options) {
  await mkdir(join(directory, "runs"));
  const tasks = selected.flatMap(id => Array.from({ length: repetitions }, (_, index) => index + 1).flatMap(repetition =>
    (repetition % 2 ? variants : [...variants].reverse()).map(variant => ({ id, variant, repetition }))));
  const runs = await pool(tasks, jobs, async task => {
    const record = await arm(task, provider, model, timeout, directory);
    console.log(`${record.status.toUpperCase()} ${record.case} ${record.variant} #${record.repetition}`);
    return record;
  });
  const names = variants.map(variant => variant.name);
  const summary = summarize(runs, names, repetitions);
  const report = { version: 5, startedAt: new Date().toISOString(), provider, model, repetitions, timeout,
    variants: variants.map(({ root: _root, ...variant }) => variant), runs };
  await writeFile(join(directory, "report.json"), JSON.stringify(report, null, 2), { mode: 0o600 });
  await writeFile(join(directory, "report.txt"), summary + "\n", { mode: 0o600 });
  console.log(`\n${summary}\nReport: ${directory}`);
  process.exitCode = runs.some(run => run.status === "error") ? 1 : 0;
}

if (import.meta.main) await main().catch(error => { console.error(error.message); process.exitCode = 1; });

import { mkdir } from "node:fs/promises";
import { dirname, extname, resolve } from "node:path";
import { ROOT } from "../../../../scripts/lib.ts";
import { debugEndpoint } from "../../../../scripts/debug-ws.ts";
import { loadEvalContext, request, type ResolvedTarget } from "../eval/live.ts";
import { parseTarget, scoreResponse, validateCases, type EvalCase, type EvalTarget } from "../eval/scorer.ts";

export type BenchmarkDimensions = {
  tool: "none" | "memory" | "service" | "web";
  orchestration: "none" | "single" | "parallel" | "dependent";
  conversation: "single-turn" | "multi-turn";
};

type BenchmarkScenario = {
  id: string;
  dimensions: BenchmarkDimensions;
  turnCaseIds: readonly string[];
};

export const benchmarkScenarios = [
  {
    id: "direct-answer",
    dimensions: { tool: "none", orchestration: "none", conversation: "single-turn" },
    turnCaseIds: ["direct-answer"],
  },
  {
    id: "memory-tool-call",
    dimensions: { tool: "memory", orchestration: "single", conversation: "single-turn" },
    turnCaseIds: ["javascript-fs-read-discovery"],
  },
  {
    id: "service-tool-call",
    dimensions: { tool: "service", orchestration: "single", conversation: "single-turn" },
    turnCaseIds: ["javascript-service-invoke"],
  },
  {
    id: "web-tool-call",
    dimensions: { tool: "web", orchestration: "single", conversation: "single-turn" },
    turnCaseIds: ["javascript-web-search-discovery"],
  },
  {
    id: "parallel-tool-calls",
    dimensions: { tool: "web", orchestration: "parallel", conversation: "single-turn" },
    turnCaseIds: ["javascript-parallel-web-search"],
  },
  {
    id: "dependent-tool-calls",
    dimensions: { tool: "web", orchestration: "dependent", conversation: "single-turn" },
    turnCaseIds: ["javascript-dependent-web-search-fetch"],
  },
  {
    id: "back-and-forth",
    dimensions: { tool: "none", orchestration: "none", conversation: "multi-turn" },
    turnCaseIds: ["back-and-forth-initial", "back-and-forth-follow-up"],
  },
] as const satisfies readonly BenchmarkScenario[];

export const benchmarkCaseIds = benchmarkScenarios.map((scenario) => scenario.id);

export type BenchmarkUsage = {
  input: number;
  output: number;
  cachedInput: number;
  totalTokens: number;
};

export type BenchmarkTrial = {
  trial: number;
  passed: boolean;
  ttftMs?: number;
  toolReadyMs?: number;
  totalMs?: number;
  tokensPerSecond?: number;
  cacheCoverage?: number;
  usage?: BenchmarkUsage;
  stopReason?: string;
  checks: Array<{ passed: boolean; detail: string }>;
  error?: string;
  turns: BenchmarkTurn[];
};

export type BenchmarkTurn = {
  turn: number;
  prompt: string;
  passed: boolean;
  ttftMs?: number;
  toolReadyMs?: number;
  totalMs?: number;
  usage?: BenchmarkUsage;
  stopReason?: string;
  checks: Array<{ passed: boolean; detail: string }>;
  error?: string;
};

export type BenchmarkSummary = {
  trials: number;
  successful: number;
  failed: number;
  ttftMs: { p50: number | null; p90: number | null };
  toolReadyMs: { p50: number | null; p90: number | null };
  totalMs: { p50: number | null; p90: number | null };
  tokensPerSecond: { p50: number | null; p90: number | null };
  cacheCoverage: { p50: number | null; p90: number | null };
};

export type BenchmarkResult = {
  target: ResolvedTarget;
  case: string;
  dimensions: BenchmarkDimensions;
  turnCaseIds: string[];
  prompts: string[];
  warmups: BenchmarkTrial[];
  trials: BenchmarkTrial[];
  summary: BenchmarkSummary;
};

export type BenchmarkComparison = {
  target: EvalTarget;
  case: string;
  ttftP50Percent: number | null;
  toolReadyP50Percent: number | null;
  totalP50Percent: number | null;
  tokensPerSecondP50Percent: number | null;
};

export type BenchmarkArtifact = {
  version: 4;
  mode: "model";
  startedAt: string;
  finishedAt: string;
  elapsedMs: number;
  git: { commit: string; workingTree: "clean" | "dirty" };
  endpoint: string;
  corpus: string;
  caseIds: string[];
  runs: number;
  warmups: number;
  timeoutMs: number;
  minimumPassRate: number;
  targets: ResolvedTarget[];
  results: BenchmarkResult[];
  comparison?: { baseline: string; results: BenchmarkComparison[]; regressionLimitPercent?: number };
  passed: boolean;
};

type Options = {
  targets: EvalTarget[];
  caseIds: string[];
  casesPath: string;
  chat: string;
  runs: number;
  warmups: number;
  timeoutMs: number;
  minimumPassRate: number;
  output: string;
  baseline: string;
  regressionLimitPercent?: number;
};

function valueAfter(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} needs a value`);
  return value;
}

function integer(value: string, flag: string, minimum: number): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < minimum) throw new Error(`${flag} must be an integer of at least ${minimum}`);
  return parsed;
}

function percentage(value: string, flag: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) throw new Error(`${flag} must be a non-negative number`);
  return parsed;
}

function passRate(value: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0 || parsed > 1) throw new Error("--min-pass-rate must be greater than 0 and at most 1");
  return parsed;
}

function usage(): string {
  return `Usage: bun ios/tests/llm/benchmark/run.ts --target <provider=client:model> [options]

Options:
  --target <provider=client:model>  Model to benchmark; repeat for more targets
  --case <id>                      Benchmark selected scenarios; repeat as needed
  --cases <path>                   Eval corpus path (default ios/tests/llm/cases/acceptance.json)
  --chat <id>                      Fresh chat whose rendered prompt and tools seed every run
  --runs <count>                   Measured trials per case and target (default 5)
  --warmups <count>                Unmeasured warmups per case and target (default 1)
  --timeout <ms>                   Timeout per model response (default 120000)
  --min-pass-rate <0..1>           Required behavioral pass rate per case (default 0.8)
  --output <path>                  JSON artifact path
  --baseline <path>                Prior JSON artifact to compare
  --fail-regression-percent <n>    Fail when median TTFT or total time regresses by more than n%

Example:
  OX_DEBUG_ENDPOINT=ws://127.0.0.1:9101 bun ios/tests/llm/benchmark/run.ts --target openai=chatgpt:gpt-5.6-sol`;
}

function parseOptions(args: string[]): Options | undefined {
  if (args.includes("-h") || args.includes("--help")) {
    console.log(usage());
    return undefined;
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const options: Options = {
    targets: [],
    caseIds: [],
    casesPath: resolve(ROOT, "ios/tests/llm/cases/acceptance.json"),
    chat: "",
    runs: 5,
    warmups: 1,
    timeoutMs: 120_000,
    minimumPassRate: 0.8,
    output: resolve(ROOT, `ios/build/llm-benchmarks/${stamp}.json`),
    baseline: "",
  };
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--target") options.targets.push(parseTarget(valueAfter(args, index++, argument)));
    else if (argument === "--case") options.caseIds.push(valueAfter(args, index++, argument));
    else if (argument === "--cases") options.casesPath = resolve(ROOT, valueAfter(args, index++, argument));
    else if (argument === "--chat") options.chat = valueAfter(args, index++, argument);
    else if (argument === "--runs") options.runs = integer(valueAfter(args, index++, argument), argument, 1);
    else if (argument === "--warmups") options.warmups = integer(valueAfter(args, index++, argument), argument, 0);
    else if (argument === "--timeout") options.timeoutMs = integer(valueAfter(args, index++, argument), argument, 1);
    else if (argument === "--min-pass-rate") options.minimumPassRate = passRate(valueAfter(args, index++, argument));
    else if (argument === "--output") options.output = resolve(ROOT, valueAfter(args, index++, argument));
    else if (argument === "--baseline") options.baseline = resolve(ROOT, valueAfter(args, index++, argument));
    else if (argument === "--fail-regression-percent") options.regressionLimitPercent = percentage(valueAfter(args, index++, argument), argument);
    else throw new Error(`Unknown option ${argument}`);
  }
  if (options.targets.length === 0) throw new Error("Pass at least one --target provider=client:model");
  const identities = options.targets.map((target) => `${target.client}:${target.model}`);
  if (new Set(identities).size !== identities.length) throw new Error("Duplicate client:model target");
  if (new Set(options.caseIds).size !== options.caseIds.length) throw new Error("Duplicate --case id");
  if (options.regressionLimitPercent !== undefined && !options.baseline) throw new Error("--fail-regression-percent requires --baseline");
  return options;
}

export function percentile(values: number[], fraction: number): number | null {
  if (values.length === 0) return null;
  if (!Number.isFinite(fraction) || fraction < 0 || fraction > 1) throw new Error("percentile fraction must be between 0 and 1");
  const sorted = [...values].sort((left, right) => left - right);
  const position = (sorted.length - 1) * fraction;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  const weight = position - lower;
  return rounded(sorted[lower]! * (1 - weight) + sorted[upper]! * weight);
}

function rounded(value: number): number {
  return Math.round(value * 100) / 100;
}

function distribution(values: number[]): { p50: number | null; p90: number | null } {
  return { p50: percentile(values, 0.5), p90: percentile(values, 0.9) };
}

export function summarizeTrials(trials: BenchmarkTrial[]): BenchmarkSummary {
  const successful = trials.filter((trial) => trial.passed && trial.ttftMs !== undefined && trial.totalMs !== undefined);
  return {
    trials: trials.length,
    successful: successful.length,
    failed: trials.length - successful.length,
    ttftMs: distribution(successful.map((trial) => trial.ttftMs!)),
    toolReadyMs: distribution(successful.flatMap((trial) => trial.toolReadyMs === undefined ? [] : [trial.toolReadyMs])),
    totalMs: distribution(successful.map((trial) => trial.totalMs!)),
    tokensPerSecond: distribution(successful.flatMap((trial) => trial.tokensPerSecond === undefined ? [] : [trial.tokensPerSecond])),
    cacheCoverage: distribution(successful.flatMap((trial) => trial.cacheCoverage === undefined ? [] : [trial.cacheCoverage])),
  };
}

function numericUsage(value: unknown): BenchmarkUsage | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const fields = value as Record<string, unknown>;
  if (![fields.input, fields.output, fields.cachedInput, fields.totalTokens].every((field) => typeof field === "number")) return undefined;
  return fields as BenchmarkUsage;
}

type HistoryTurn = { user: string; assistant: Record<string, unknown> };

type TurnOutcome = {
  record: BenchmarkTurn;
  assistant?: Record<string, unknown>;
};

function turnFromResponse(testCase: EvalCase, turn: number, response: Record<string, unknown>): TurnOutcome {
  const score = scoreResponse(testCase, response);
  const ttftMs = typeof response.ttftMs === "number" ? response.ttftMs : undefined;
  const toolReadyMs = typeof response.toolReadyMs === "number" ? response.toolReadyMs : undefined;
  const totalMs = typeof response.totalMs === "number" ? response.totalMs : undefined;
  const message = response.message && typeof response.message === "object" ? response.message as Record<string, unknown> : undefined;
  const usage = numericUsage(message?.usage);
  return {
    record: {
      turn,
      prompt: testCase.prompt,
      passed: score.passed,
      ttftMs,
      toolReadyMs,
      totalMs,
      usage,
      stopReason: typeof message?.stopReason === "string" ? message.stopReason : undefined,
      checks: score.checks,
      error: typeof response.error === "string" ? response.error : undefined,
    },
    assistant: message,
  };
}

async function runTurn(
  target: ResolvedTarget,
  sessionId: string,
  testCase: EvalCase,
  turn: number,
  history: HistoryTurn[],
  timeoutMs: number,
): Promise<TurnOutcome> {
  let response: Record<string, unknown>;
  try {
    response = await request({
      kind: "run-agent",
      sessionId,
      clientId: target.client,
      modelId: target.model,
      prompt: testCase.prompt,
      historyOverride: history.length > 0 ? history : undefined,
    }, timeoutMs);
  } catch (error) {
    response = { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
  return turnFromResponse(testCase, turn, response);
}

function combinedUsage(turns: BenchmarkTurn[]): BenchmarkUsage | undefined {
  const usage = turns.flatMap((turn) => turn.usage ? [turn.usage] : []);
  if (usage.length !== turns.length) return undefined;
  return usage.reduce((total, sample) => ({
    input: total.input + sample.input,
    output: total.output + sample.output,
    cachedInput: total.cachedInput + sample.cachedInput,
    totalTokens: total.totalTokens + sample.totalTokens,
  }), { input: 0, output: 0, cachedInput: 0, totalTokens: 0 });
}

async function runScenarioTrial(
  target: ResolvedTarget,
  sessionId: string,
  cases: EvalCase[],
  trial: number,
  timeoutMs: number,
): Promise<BenchmarkTrial> {
  const history: HistoryTurn[] = [];
  const turns: BenchmarkTurn[] = [];
  for (let index = 0; index < cases.length; index++) {
    const testCase = cases[index]!;
    const outcome = await runTurn(target, sessionId, testCase, index + 1, history, timeoutMs);
    turns.push(outcome.record);
    if (!outcome.assistant) break;
    history.push({ user: testCase.prompt, assistant: outcome.assistant });
  }
  return assembleTrial(cases, trial, turns);
}

export function assembleTrial(cases: EvalCase[], trial: number, turns: BenchmarkTurn[]): BenchmarkTrial {
  const usage = combinedUsage(turns);
  const finalTurn = turns.at(-1);
  const completeTiming = turns.length === cases.length && turns.every((turn) => turn.totalMs !== undefined && turn.ttftMs !== undefined);
  const totalMs = completeTiming ? turns.reduce((total, turn) => total + turn.totalMs!, 0) : undefined;
  const generationMs = completeTiming ? turns.reduce((total, turn) => total + Math.max(1, turn.totalMs! - turn.ttftMs!), 0) : undefined;
  const textOnly = cases.every((testCase) => testCase.group === "no_tool");
  return {
    trial,
    passed: turns.length === cases.length && turns.every((turn) => turn.passed),
    ttftMs: finalTurn?.ttftMs,
    toolReadyMs: finalTurn?.toolReadyMs,
    totalMs,
    tokensPerSecond: textOnly && usage && generationMs ? rounded(usage.output / (generationMs / 1_000)) : undefined,
    cacheCoverage: usage && usage.input > 0 ? rounded(usage.cachedInput / usage.input) : undefined,
    usage,
    stopReason: finalTurn?.stopReason,
    checks: turns.flatMap((turn) => turn.checks.map((check) => ({ ...check, detail: `turn ${turn.turn}: ${check.detail}` }))),
    error: turns.find((turn) => turn.error)?.error,
    turns,
  };
}

async function benchmarkScenario(
  target: ResolvedTarget,
  sessionId: string,
  scenario: { id: string; dimensions: BenchmarkDimensions; cases: EvalCase[] },
  options: Options,
): Promise<BenchmarkResult> {
  const warmups: BenchmarkTrial[] = [];
  const trials: BenchmarkTrial[] = [];
  for (let index = 1; index <= options.warmups; index++) {
    console.log(`  warmup ${target.provider} ${scenario.id} ${index}/${options.warmups}`);
    warmups.push(await runScenarioTrial(target, sessionId, scenario.cases, index, options.timeoutMs));
  }
  for (let index = 1; index <= options.runs; index++) {
    const trial = await runScenarioTrial(target, sessionId, scenario.cases, index, options.timeoutMs);
    trials.push(trial);
    const toolReady = trial.toolReadyMs === undefined ? "" : ` · tool ready ${trial.toolReadyMs}ms`;
    const timing = trial.ttftMs === undefined || trial.totalMs === undefined ? "timing unavailable" : `final ttft ${trial.ttftMs}ms${toolReady} · workflow ${trial.totalMs}ms`;
    console.log(`  ${trial.passed ? "✓" : "✗"} ${target.provider} ${scenario.id} ${index}/${options.runs} · ${timing}`);
  }
  return {
    target,
    case: scenario.id,
    dimensions: scenario.dimensions,
    turnCaseIds: scenario.cases.map((testCase) => testCase.id),
    prompts: scenario.cases.map((testCase) => testCase.prompt),
    warmups,
    trials,
    summary: summarizeTrials(trials),
  };
}

function targetIdentity(target: EvalTarget): string {
  return `${target.client}:${target.model}`;
}

function percentChange(current: number | null, baseline: number | null): number | null {
  if (current === null || baseline === null || baseline === 0) return null;
  return rounded((current - baseline) / baseline * 100);
}

export function compareResults(current: BenchmarkResult[], baseline: BenchmarkResult[]): BenchmarkComparison[] {
  const previous = new Map(baseline.map((result) => [`${targetIdentity(result.target)}:${result.case}`, result]));
  return current.flatMap((result) => {
    const match = previous.get(`${targetIdentity(result.target)}:${result.case}`);
    if (!match) return [];
    return [{
      target: result.target,
      case: result.case,
      ttftP50Percent: percentChange(result.summary.ttftMs.p50, match.summary.ttftMs.p50),
      toolReadyP50Percent: percentChange(result.summary.toolReadyMs.p50, match.summary.toolReadyMs.p50),
      totalP50Percent: percentChange(result.summary.totalMs.p50, match.summary.totalMs.p50),
      tokensPerSecondP50Percent: percentChange(result.summary.tokensPerSecond.p50, match.summary.tokensPerSecond.p50),
    }];
  });
}

function metric(value: number | null, suffix = ""): string {
  return value === null ? "—" : `${rounded(value)}${suffix}`;
}

export function renderMarkdown(artifact: BenchmarkArtifact): string {
  const rows = artifact.results.map((result) => {
    const summary = result.summary;
    return `| ${targetIdentity(result.target)} | ${result.case} | ${result.dimensions.tool} | ${result.dimensions.orchestration} | ${result.dimensions.conversation} | ${summary.successful}/${summary.trials} | ${metric(summary.ttftMs.p50)} | ${metric(summary.ttftMs.p90)} | ${metric(summary.toolReadyMs.p50)} | ${metric(summary.toolReadyMs.p90)} | ${metric(summary.totalMs.p50)} | ${metric(summary.totalMs.p90)} | ${metric(summary.tokensPerSecond.p50)} | ${metric(summary.cacheCoverage.p50 === null ? null : summary.cacheCoverage.p50 * 100, "%")} |`;
  }).join("\n");
  const comparison = artifact.comparison && artifact.comparison.results.length > 0
    ? `\n## Baseline Comparison\n\nBaseline: \`${artifact.comparison.baseline}\`\n\n| Target | Interaction | Final TTFT p50 | Tool ready p50 | Workflow p50 | Tokens/s p50 |\n| --- | --- | ---: | ---: | ---: | ---: |\n${artifact.comparison.results.map((result) => `| ${targetIdentity(result.target)} | ${result.case} | ${metric(result.ttftP50Percent, "%")} | ${metric(result.toolReadyP50Percent, "%")} | ${metric(result.totalP50Percent, "%")} | ${metric(result.tokensPerSecondP50Percent, "%")} |`).join("\n")}\n`
    : "";
  return `# LLM Latency Benchmark

- Started: ${artifact.startedAt}
- Git commit: \`${artifact.git.commit}\` (${artifact.git.workingTree})
- Debug endpoint: \`${artifact.endpoint}\`
- Measurement: model stream
- Runs: ${artifact.runs} measured, ${artifact.warmups} warmup
- Required pass rate: ${rounded(artifact.minimumPassRate * 100)}%
- Result: ${artifact.passed ? "PASS" : "FAIL"}

| Target | Interaction | Tool | Orchestration | Conversation | Success | Final TTFT p50 ms | Final TTFT p90 ms | Tool ready p50 ms | Tool ready p90 ms | Workflow p50 ms | Workflow p90 ms | Tokens/s p50 | Cache p50 |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
${rows}
${comparison}`;
}

async function gitValue(args: string[]): Promise<string> {
  const process = Bun.spawn(["git", ...args], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  const [stdout, exit] = await Promise.all([new Response(process.stdout).text(), process.exited]);
  if (exit !== 0) return "unknown";
  return stdout.trim();
}

function markdownPath(jsonPath: string): string {
  return extname(jsonPath).toLowerCase() === ".json" ? jsonPath.slice(0, -5) + ".md" : `${jsonPath}.md`;
}

function exceedsRegressionLimit(comparisons: BenchmarkComparison[], limit: number | undefined): boolean {
  if (limit === undefined) return false;
  return comparisons.some((comparison) => [comparison.ttftP50Percent, comparison.toolReadyP50Percent, comparison.totalP50Percent].some((value) => value !== null && value > limit));
}

async function runBenchmark(args: string[]): Promise<void> {
  const options = parseOptions(args);
  if (!options) return;
  const startedAt = Date.now();
  const corpus = validateCases(await Bun.file(options.casesPath).json());
  const selectedIds = options.caseIds.length > 0 ? options.caseIds : [...benchmarkCaseIds];
  const byId = new Map(corpus.map((testCase) => [testCase.id, testCase]));
  const scenariosById = new Map<string, (typeof benchmarkScenarios)[number]>(benchmarkScenarios.map((scenario) => [scenario.id, scenario]));
  const missing = selectedIds.filter((id) => !scenariosById.has(id));
  if (missing.length > 0) throw new Error(`Unknown scenario ids: ${missing.join(", ")}`);
  const selected = selectedIds.map((id) => {
    const scenario = scenariosById.get(id)!;
    const missingCases = scenario.turnCaseIds.filter((caseId) => !byId.has(caseId));
    if (missingCases.length > 0) throw new Error(`Scenario ${id} has unknown turn cases: ${missingCases.join(", ")}`);
    return { id, dimensions: scenario.dimensions, cases: scenario.turnCaseIds.map((caseId) => byId.get(caseId)!) };
  });
  const { targets, snapshot } = await loadEvalContext(options.targets, options.chat);
  const results: BenchmarkResult[] = [];
  for (const target of targets) {
    console.log(`\n${target.provider} · ${target.client}:${target.model}`);
    for (const scenario of selected) {
      if (scenario.cases.some((testCase) => testCase.group !== "no_tool") && !target.supportsTools) throw new Error(`Scenario ${scenario.id} requires tools, but ${target.client}:${target.model} does not support them`);
      results.push(await benchmarkScenario(target, snapshot.id, scenario, options));
    }
  }
  let comparison: BenchmarkArtifact["comparison"];
  let comparisons: BenchmarkComparison[] = [];
  if (options.baseline) {
    const baseline = await Bun.file(options.baseline).json() as BenchmarkArtifact;
    if (baseline.version !== 4 || baseline.mode !== "model" || !Array.isArray(baseline.results)) throw new Error("Baseline is not a model LLM benchmark artifact version 4");
    comparisons = compareResults(results, baseline.results);
    if (comparisons.length === 0) throw new Error("Baseline has no matching client:model and case results");
    comparison = { baseline: options.baseline, results: comparisons, regressionLimitPercent: options.regressionLimitPercent };
  }
  const commit = await gitValue(["rev-parse", "HEAD"]);
  const status = await gitValue(["status", "--porcelain"]);
  const behaviorPassed = results.every((result) => result.summary.successful / result.summary.trials >= options.minimumPassRate);
  const regressionPassed = !exceedsRegressionLimit(comparisons, options.regressionLimitPercent);
  const artifact: BenchmarkArtifact = {
    version: 4,
    mode: "model",
    startedAt: new Date(startedAt).toISOString(),
    finishedAt: new Date().toISOString(),
    elapsedMs: Date.now() - startedAt,
    git: { commit, workingTree: status ? "dirty" : "clean" },
    endpoint: debugEndpoint(),
    corpus: options.casesPath,
    caseIds: selectedIds,
    runs: options.runs,
    warmups: options.warmups,
    timeoutMs: options.timeoutMs,
    minimumPassRate: options.minimumPassRate,
    targets,
    results,
    comparison,
    passed: behaviorPassed && regressionPassed,
  };
  await mkdir(dirname(options.output), { recursive: true });
  await Promise.all([
    Bun.write(options.output, `${JSON.stringify(artifact, null, 2)}\n`),
    Bun.write(markdownPath(options.output), renderMarkdown(artifact)),
  ]);
  console.log(`\n${artifact.passed ? "PASS" : "FAIL"} LLM latency benchmark`);
  console.log(options.output);
  console.log(markdownPath(options.output));
  if (!artifact.passed) process.exitCode = 1;
}

if (import.meta.main) {
  try {
    await runBenchmark(Bun.argv.slice(2));
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}

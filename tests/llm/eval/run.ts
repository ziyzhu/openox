import { mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { ROOT } from "../../../scripts/lib.ts";
import { acceptanceCases, boundedSuiteTimeout, defaultProviderConcurrency, defaultSuiteTimeoutMs, parallelMap } from "./execution.ts";
import { loadEvalContext, request, type EvalSnapshot, type ResolvedTarget } from "./live.ts";
import { evalGroups, parseTarget, passesThreshold, scoreResponse, validateCases, validateProviderCoverage, type EvalCase, type EvalGroup, type EvalTarget } from "./scorer.ts";

export type PromptCacheUsage = {
  input: number;
  output: number;
  cachedInput: number;
  totalTokens: number;
};

export type PromptCacheSample = {
  phase: "warmup" | "without_system" | "measured";
  usage?: PromptCacheUsage;
  ttftMs?: number;
  totalMs?: number;
  error?: string;
};

type PromptCacheEvaluation = {
  passed: boolean;
  systemPromptTokens: number | null;
  cachedInput: number | null;
  coverage: number | null;
  samples: PromptCacheSample[];
  error?: string;
};

function tokenCount(value: unknown, field: string): number {
  if (!Number.isInteger(value) || (value as number) < 0) throw new Error(`response usage.${field} must be a non-negative integer`);
  return value as number;
}

export function parsePromptCacheUsage(response: Record<string, unknown>): PromptCacheUsage {
  if (response.ok !== true) throw new Error(String(response.error ?? "model request failed"));
  const message = response.message;
  if (!message || typeof message !== "object" || Array.isArray(message)) throw new Error("model response has no message");
  const usage = (message as Record<string, unknown>).usage;
  if (!usage || typeof usage !== "object" || Array.isArray(usage)) throw new Error("model response has no usage");
  const fields = usage as Record<string, unknown>;
  return {
    input: tokenCount(fields.input, "input"),
    output: tokenCount(fields.output, "output"),
    cachedInput: tokenCount(fields.cachedInput, "cachedInput"),
    totalTokens: tokenCount(fields.totalTokens, "totalTokens"),
  };
}

export function assessPromptCache(samples: PromptCacheSample[]): PromptCacheEvaluation {
  const phases: PromptCacheSample["phase"][] = ["warmup", "without_system", "measured"];
  const failedPhase = phases.find((phase) => {
    const sample = samples.find((candidate) => candidate.phase === phase);
    return !sample?.usage || sample.error;
  });
  if (failedPhase) {
    const failed = samples.find((sample) => sample.phase === failedPhase);
    return {
      passed: false,
      systemPromptTokens: null,
      cachedInput: null,
      coverage: null,
      samples,
      error: `${failedPhase}: ${failed?.error ?? "missing usage"}`,
    };
  }
  const warmup = samples.find((sample) => sample.phase === "warmup")!.usage!;
  const withoutSystem = samples.find((sample) => sample.phase === "without_system")!.usage!;
  const measured = samples.find((sample) => sample.phase === "measured")!.usage!;
  if (warmup.input !== measured.input) {
    return {
      passed: false,
      systemPromptTokens: null,
      cachedInput: measured.cachedInput,
      coverage: null,
      samples,
      error: `identical full-prompt requests reported different input counts: ${warmup.input} and ${measured.input}`,
    };
  }
  const systemPromptTokens = measured.input - withoutSystem.input;
  if (systemPromptTokens <= 0) {
    return {
      passed: false,
      systemPromptTokens,
      cachedInput: measured.cachedInput,
      coverage: null,
      samples,
      error: `could not isolate positive system-prompt usage from ${measured.input} full and ${withoutSystem.input} without-system input tokens`,
    };
  }
  const coverage = measured.cachedInput / systemPromptTokens;
  const passed = measured.cachedInput >= systemPromptTokens;
  return {
    passed,
    systemPromptTokens,
    cachedInput: measured.cachedInput,
    coverage,
    samples,
    error: passed ? undefined : `cached ${measured.cachedInput} tokens, fewer than the system prompt's ${systemPromptTokens} tokens`,
  };
}

function requestTimeout(deadline: number, timeoutMs: number): number {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error("suite timeout during prompt-cache eval");
  return Math.min(timeoutMs, remaining);
}

async function collectPromptCacheSample(
  phase: PromptCacheSample["phase"],
  target: ResolvedTarget,
  snapshot: EvalSnapshot,
  systemPromptOverride: string,
  timeoutMs: number,
  deadline: number,
): Promise<PromptCacheSample> {
  try {
    const response = await request({
      kind: "run-agent",
      sessionId: snapshot.id,
      clientId: target.client,
      modelId: target.model,
      prompt: "Reply with exactly OK.",
      systemPromptOverride,
    }, requestTimeout(deadline, timeoutMs));
    return {
      phase,
      usage: parsePromptCacheUsage(response),
      ttftMs: typeof response.ttftMs === "number" ? response.ttftMs : undefined,
      totalMs: typeof response.totalMs === "number" ? response.totalMs : undefined,
    };
  } catch (error) {
    return { phase, error: error instanceof Error ? error.message : String(error) };
  }
}

async function evaluatePromptCache(
  target: ResolvedTarget,
  snapshot: EvalSnapshot,
  timeoutMs: number,
  deadline: number,
): Promise<PromptCacheEvaluation> {
  const samples: PromptCacheSample[] = [];
  samples.push(await collectPromptCacheSample("warmup", target, snapshot, snapshot.systemPrompt, timeoutMs, deadline));
  if (samples[0]!.error) return assessPromptCache(samples);
  samples.push(await collectPromptCacheSample("without_system", target, snapshot, "", timeoutMs, deadline));
  if (samples[1]!.error) return assessPromptCache(samples);
  samples.push(await collectPromptCacheSample("measured", target, snapshot, snapshot.systemPrompt, timeoutMs, deadline));
  return assessPromptCache(samples);
}

type Options = {
  targets: EvalTarget[];
  casesPath: string;
  caseIds: string[];
  groups: EvalGroup[];
  chat: string;
  runs: number;
  minimum: number;
  timeoutMs: number;
  providerConcurrency: number;
  suiteTimeoutMs: number;
  output: string;
  allowSingleProvider: boolean;
};

function valueAfter(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} needs a value`);
  return value;
}

function positiveInteger(value: string, flag: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) throw new Error(`${flag} must be a positive integer`);
  return parsed;
}

function usage(): string {
  return `Usage: bun tests/llm/eval/run.ts --target <provider=client:model> --target <provider=client:model> [options]

Options:
  --target <provider=client:model>  Repeat for every provider and model
  --case <id>                      Run selected cases only; repeat as needed
  --group <tool>                   Run one acceptance tool group; repeat as needed
  --cases <path>                   Corpus path (default tests/llm/cases/acceptance.json)
  --chat <id>                      Chat whose rendered Ox prompt and tools seed every run
  --runs <count>                   Trials per case and target (default 3)
  --min-pass-rate <0..1>           Required rate per case and target (default 2/3)
  --timeout <ms>                   Timeout per model response (default 45000)
  --provider-concurrency <count>   Concurrent responses per provider family (default 20)
  --suite-timeout <ms>             Hard whole-suite budget (default 50000)
  --output <path>                  JSON artifact path
  --allow-single-provider          Permit a focused one-provider diagnostic run

Examples:
  bun tests/llm/eval/run.ts --target openai=chatgpt:gpt-5.6-sol --target google=gemini:gemini-3.6-flash
  bun tests/llm/eval/run.ts --target openai=chatgpt:gpt-5.6-sol --allow-single-provider --group execute`;
}

function parseOptions(args: string[]): Options | undefined {
  if (args.includes("-h") || args.includes("--help")) {
    console.log(usage());
    return undefined;
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const options: Options = {
    targets: [],
    casesPath: join(ROOT, "tests/llm/cases/acceptance.json"),
    caseIds: [],
    groups: [],
    chat: "",
    runs: 3,
    minimum: 2 / 3,
    timeoutMs: 45_000,
    providerConcurrency: defaultProviderConcurrency,
    suiteTimeoutMs: defaultSuiteTimeoutMs,
    output: join(ROOT, `ios/build/llm-evals/${stamp}.json`),
    allowSingleProvider: false,
  };
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--target") options.targets.push(parseTarget(valueAfter(args, index++, argument)));
    else if (argument === "--case") options.caseIds.push(valueAfter(args, index++, argument));
    else if (argument === "--group") {
      const group = valueAfter(args, index++, argument) as EvalGroup;
      if (!evalGroups.includes(group)) throw new Error(`--group must be one of ${evalGroups.join(", ")}`);
      options.groups.push(group);
    }
    else if (argument === "--cases") options.casesPath = valueAfter(args, index++, argument);
    else if (argument === "--chat") options.chat = valueAfter(args, index++, argument);
    else if (argument === "--runs") options.runs = positiveInteger(valueAfter(args, index++, argument), argument);
    else if (argument === "--timeout") options.timeoutMs = positiveInteger(valueAfter(args, index++, argument), argument);
    else if (argument === "--provider-concurrency") options.providerConcurrency = positiveInteger(valueAfter(args, index++, argument), argument);
    else if (argument === "--suite-timeout") {
      options.suiteTimeoutMs = boundedSuiteTimeout(positiveInteger(valueAfter(args, index++, argument), argument));
    }
    else if (argument === "--output") options.output = valueAfter(args, index++, argument);
    else if (argument === "--min-pass-rate") {
      options.minimum = Number(valueAfter(args, index++, argument));
      if (!Number.isFinite(options.minimum) || options.minimum <= 0 || options.minimum > 1) throw new Error("--min-pass-rate must be greater than 0 and at most 1");
    } else if (argument === "--allow-single-provider") options.allowSingleProvider = true;
    else throw new Error(`Unknown option ${argument}`);
  }
  validateProviderCoverage(options.targets, options.allowSingleProvider);
  return options;
}

async function runEval(args: string[]): Promise<void> {
  const startedAt = Date.now();
  const options = parseOptions(args);
  if (!options) return;
  const deadline = startedAt + options.suiteTimeoutMs;

  const corpus = validateCases(await Bun.file(options.casesPath).json());
  const candidates = options.caseIds.length === 0 ? acceptanceCases(corpus) : corpus.filter((testCase) => options.caseIds.includes(testCase.id));
  const selected = options.groups.length === 0 ? candidates : candidates.filter((testCase) => options.groups.includes(testCase.group));
  const missingCases = options.caseIds.filter((id) => !corpus.some((testCase) => testCase.id === id));
  if (missingCases.length > 0) throw new Error(`Unknown case ids: ${missingCases.join(", ")}`);
  if (selected.length === 0) throw new Error("No eval cases selected");

  const { targets, snapshot } = await loadEvalContext(options.targets, options.chat, deadline);

  const casesByTarget = targets.map((target) => ({
    target,
    cases: selected.filter((testCase) => testCase.group === "no_tool" || target.supportsTools),
  }));
  const artifact: Record<string, unknown> = {
    startedAt: new Date(startedAt).toISOString(),
    chat: snapshot.id,
    corpus: options.casesPath,
    runs: options.runs,
    minimumPassRate: options.minimum,
    providerConcurrency: options.providerConcurrency,
    suiteTimeoutMs: options.suiteTimeoutMs,
    targets,
    promptCache: [],
    results: [],
  };
  const results = artifact.results as Array<Record<string, unknown>>;
  let failed = false;

  type CacheJob = { kind: "cache"; entryIndex: number };
  type TrialJob = { kind: "trial"; entryIndex: number; testCase: EvalCase; trial: number };
  type CacheResult = CacheJob & { evaluation: PromptCacheEvaluation };
  type TrialResult = TrialJob & { outcome: Record<string, unknown> & { passed: boolean } };
  type ProviderJob = CacheJob | TrialJob;
  type ProviderResult = CacheResult | TrialResult;
  const jobsByProvider = new Map<string, ProviderJob[]>();
  for (let entryIndex = 0; entryIndex < casesByTarget.length; entryIndex++) {
    const provider = casesByTarget[entryIndex]!.target.provider;
    const jobs = jobsByProvider.get(provider) ?? [];
    jobs.push({ kind: "cache", entryIndex });
    jobsByProvider.set(provider, jobs);
  }
  for (const testCase of selected) {
    for (let entryIndex = 0; entryIndex < casesByTarget.length; entryIndex++) {
      const entry = casesByTarget[entryIndex]!;
      if (!entry.cases.includes(testCase)) continue;
      const jobs = jobsByProvider.get(entry.target.provider) ?? [];
      for (let trial = 1; trial <= options.runs; trial++) jobs.push({ kind: "trial", entryIndex, testCase, trial });
      jobsByProvider.set(entry.target.provider, jobs);
    }
  }
  const totalTrials = [...jobsByProvider.values()].flat().filter((job) => job.kind === "trial").length;
  const totalCacheChecks = casesByTarget.length;
  let completedTrials = 0;
  console.log(`Running ${totalTrials} trials and ${totalCacheChecks} prompt-cache checks with up to ${options.providerConcurrency} concurrent responses per provider`);

  const providerResults = await Promise.all([...jobsByProvider.entries()].map(async ([provider, jobs]) => {
    return await parallelMap(jobs, options.providerConcurrency, async (job): Promise<ProviderResult> => {
      const entry = casesByTarget[job.entryIndex]!;
      if (job.kind === "cache") {
        const evaluation = await evaluatePromptCache(entry.target, snapshot, options.timeoutMs, deadline);
        const cached = evaluation.cachedInput ?? 0;
        const required = evaluation.systemPromptTokens ?? 0;
        const detail = evaluation.error ? ` · ${evaluation.error}` : "";
        console.log(`  ${evaluation.passed ? "✓" : "✗"} ${provider} prompt-cache ${cached}/${required} tokens${detail}`);
        return { ...job, evaluation };
      }
      const remainingMs = deadline - Date.now();
      let response: Record<string, unknown>;
      if (remainingMs <= 0) {
        response = { ok: false, error: `suite timeout after ${options.suiteTimeoutMs}ms` };
      } else {
        try {
          response = await request({
            kind: "run-agent",
            sessionId: snapshot.id,
            clientId: entry.target.client,
            modelId: entry.target.model,
            prompt: job.testCase.prompt,
          }, Math.min(options.timeoutMs, remainingMs));
        } catch (error) {
          response = { ok: false, error: error instanceof Error ? error.message : String(error) };
        }
      }
      const score = scoreResponse(job.testCase, response);
      const outcome = {
        trial: job.trial,
        ...score,
        ttftMs: response.ttftMs,
        totalMs: response.totalMs,
        usage: response.message && typeof response.message === "object" ? (response.message as Record<string, unknown>).usage : undefined,
        error: response.error,
        rawMessage: response.message,
      };
      completedTrials += 1;
      console.log(`  ${score.passed ? "✓" : "✗"} ${provider} ${job.testCase.id} ${job.trial}/${options.runs} (${completedTrials}/${totalTrials})`);
      return { ...job, outcome };
    });
  }));

  const flattenedResults = providerResults.flat();
  const cacheResults = flattenedResults.filter((result): result is CacheResult => result.kind === "cache");
  artifact.promptCache = cacheResults.map((result) => ({
    target: casesByTarget[result.entryIndex]!.target,
    ...result.evaluation,
  }));
  failed ||= cacheResults.length !== totalCacheChecks || cacheResults.some((result) => !result.evaluation.passed);
  const outcomesByCase = new Map<string, Array<Record<string, unknown> & { passed: boolean }>>();
  for (const trialResult of flattenedResults.filter((result): result is TrialResult => result.kind === "trial")) {
    const key = `${trialResult.entryIndex}:${trialResult.testCase.id}`;
    const outcomes = outcomesByCase.get(key) ?? [];
    outcomes[trialResult.trial - 1] = trialResult.outcome;
    outcomesByCase.set(key, outcomes);
  }
  for (let entryIndex = 0; entryIndex < casesByTarget.length; entryIndex++) {
    const entry = casesByTarget[entryIndex]!;
    for (const testCase of entry.cases) {
      const outcomes = outcomesByCase.get(`${entryIndex}:${testCase.id}`) ?? [];
      const passed = outcomes.length === options.runs && passesThreshold(outcomes, options.minimum);
      failed ||= !passed;
      results.push({ target: entry.target, group: testCase.group, case: testCase.id, passed, outcomes });
      const passCount = outcomes.filter((outcome) => outcome.passed).length;
      console.log(`  ${passed ? "PASS" : "FAIL"} ${entry.target.provider} ${testCase.id}: ${passCount}/${options.runs}`);
    }
  }

  artifact.finishedAt = new Date().toISOString();
  artifact.elapsedMs = Date.now() - startedAt;
  artifact.passed = !failed;
  await mkdir(dirname(options.output), { recursive: true });
  await Bun.write(options.output, `${JSON.stringify(artifact, null, 2)}\n`);
  console.log(`\n${failed ? "FAIL" : "PASS"} real-model eval`);
  console.log(options.output);
  if (failed) process.exitCode = 1;
}


if (import.meta.main) {
  try {
    await runEval(Bun.argv.slice(2));
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}

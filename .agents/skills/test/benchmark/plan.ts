import { createHash } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type Definition = {
  question: string;
  arms: { id: string; source: string; artifactSha256: string }[];
  cases: { id: string; prompt: string }[];
  repetitions: number;
  timeoutMs: number;
  timingBoundary: string;
  requiredChecks: string[];
  environment: { provider: string; model: string; reasoning: string; device: string; caches: string };
};

export type Trial = { index: number; pair: number; repeat: number; case: string; arm: string };
export type Plan = { version: 1; createdAt: string; definition: Definition; schedule: Trial[] };

export function text(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

export function validateDefinition(value: unknown): Definition {
  if (!value || typeof value !== "object") throw new Error("Expected a benchmark definition object");
  const d = value as Definition;
  if (!text(d.question) || !text(d.timingBoundary)) throw new Error("Declare question and timingBoundary");
  if (!Number.isSafeInteger(d.repetitions) || d.repetitions < 2) throw new Error("repetitions must be an integer >= 2");
  if (!Number.isSafeInteger(d.timeoutMs) || d.timeoutMs <= 0) throw new Error("timeoutMs must be a positive integer");
  if (!Array.isArray(d.arms) || d.arms.length !== 2 || d.arms.some(a => !a || !text(a.id) || !text(a.source) || !text(a.artifactSha256) || !/^[a-f0-9]{64}$/i.test(a.artifactSha256))) {
    throw new Error("Declare exactly two arms with id, frozen source identity and artifactSha256");
  }
  if (!Array.isArray(d.cases) || !d.cases.length || d.cases.some(c => !c || !text(c.id) || !text(c.prompt))) throw new Error("Declare cases with id and matched prompt");
  if (!Array.isArray(d.requiredChecks) || !d.requiredChecks.length || !d.requiredChecks.every(text)) throw new Error("Declare requiredChecks");
  for (const ids of [d.arms.map(a => a.id), d.cases.map(c => c.id), d.requiredChecks]) {
    if (new Set(ids).size !== ids.length) throw new Error("Arm, case and check identifiers must be unique");
  }
  if (!d.environment || ![d.environment.provider, d.environment.model, d.environment.reasoning, d.environment.device, d.environment.caches].every(text)) {
    throw new Error("Declare environment provider, model, reasoning, device and caches; use explicit not-applicable values");
  }
  return d;
}

export function schedule(d: Definition): Trial[] {
  const trials: Trial[] = [];
  let pair = 0;
  for (let repeat = 0; repeat < d.repetitions; repeat++) {
    for (let position = 0; position < d.cases.length; position++) {
      const caseIndex = (position + repeat) % d.cases.length;
      const arms = (repeat + caseIndex) % 2 ? [...d.arms].reverse() : d.arms;
      pair++;
      for (const arm of arms) trials.push({ index: trials.length + 1, pair, repeat: repeat + 1, case: d.cases[caseIndex].id, arm: arm.id });
    }
  }
  return trials;
}

export function validatePlan(value: unknown): Plan {
  const plan = value as Plan;
  if (!plan || plan.version !== 1 || !text(plan.createdAt)) throw new Error("Unsupported benchmark plan");
  const definition = validateDefinition(plan.definition);
  if (JSON.stringify(plan.schedule) !== JSON.stringify(schedule(definition))) throw new Error("Schedule differs from the declared counterbalanced design");
  return plan;
}

export function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

if (import.meta.main) {
  const args = Bun.argv.slice(2);
  if (args.length === 1 && args[0] === "--help") {
    console.log("Usage: bun .agents/skills/test/benchmark/plan.ts <definition.json>\nCreates an owned temporary directory with a frozen paired plan. Does not build, drive devices, or call providers.");
  } else {
    if (args.length !== 1) throw new Error("Expected one definition.json path; use --help");
    const definition = validateDefinition(await Bun.file(args[0]).json());
    const plan: Plan = { version: 1, createdAt: new Date().toISOString(), definition, schedule: schedule(definition) };
    const directory = await mkdtemp(join(tmpdir(), "ox-benchmark."));
    const contents = JSON.stringify(plan, null, 2) + "\n";
    await writeFile(join(directory, "plan.json"), contents, { mode: 0o600 });
    console.log(JSON.stringify({ directory, planSha256: sha256(contents), plannedTrials: plan.schedule.length }, null, 2));
  }
}

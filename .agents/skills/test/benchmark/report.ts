import { readFile, realpath, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { ROOT } from "../../../lib.ts";
import { sha256, text, validatePlan, type Trial } from "./plan.ts";

const statuses = ["verified", "task_failed", "provider_failed", "output_limit", "deadline", "blocked", "harness_failed", "setup_failed"] as const;
const metricNames = ["modelMs", "toolWallMs", "roundTrips", "inputTokens", "cachedInputTokens", "outputTokens", "costUSD"] as const;
type Metrics = Partial<Record<typeof metricNames[number], number>>;
type Result = { index: number; status: typeof statuses[number]; elapsedMs: number | null; checks: Record<string, boolean>; evidence: string; metrics?: Metrics; featureUsed?: boolean };
type Recorded = Result & Trial;

function median(values: number[]): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b), middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function mean(values: number[]): number | null {
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null;
}

function aggregate(rows: Recorded[], planned: number) {
  const verified = rows.filter(r => r.status === "verified");
  return {
    planned, recorded: rows.length, notRun: planned - rows.length, verified: verified.length,
    statuses: Object.fromEntries(statuses.map(status => [status, rows.filter(r => r.status === status).length])),
    successfulMedianMs: median(verified.map(r => r.elapsedMs!)),
    successfulMeanMs: mean(verified.map(r => r.elapsedMs!)),
    metrics: Object.fromEntries(metricNames.map(name => {
      const values = rows.flatMap(r => r.metrics?.[name] === undefined ? [] : [r.metrics[name]!]);
      return [name, { samples: values.length, total: values.length ? values.reduce((a, b) => a + b, 0) : null, median: median(values) }];
    })),
    featureUsage: { observed: rows.filter(r => typeof r.featureUsed === "boolean").length, used: rows.filter(r => r.featureUsed === true).length },
  };
}

async function report(path: string) {
  const planPath = await realpath(path), directory = dirname(planPath);
  const location = relative(await realpath(ROOT), directory);
  if (!isAbsolute(location) && location !== ".." && !location.startsWith(".." + sep)) throw new Error("Benchmark evidence must stay outside the checkout");
  const planText = await readFile(planPath, "utf8"), plan = validatePlan(JSON.parse(planText));
  const payload = JSON.parse(await readFile(join(directory, "results.json"), "utf8"));
  if (payload.planSha256 !== sha256(planText)) throw new Error("Results do not match this frozen plan's SHA-256");
  if (!Array.isArray(payload.results)) throw new Error("Expected results array");
  if (!["completed", "incomplete", "not_attempted"].includes(payload.cleanup?.status) || !text(payload.cleanup?.evidence)) throw new Error("Record cleanup status and evidence");
  const rows: Recorded[] = [], seen = new Set<number>();
  for (const r of payload.results as Result[]) {
    if (!r || !Number.isSafeInteger(r.index)) throw new Error("Result requires a scheduled index");
    const trial = plan.schedule.find(t => t.index === r.index);
    if (!trial || seen.has(r.index)) throw new Error("Unknown or duplicate trial index: " + r.index);
    seen.add(r.index);
    if (!statuses.includes(r.status) || !text(r.evidence)) throw new Error("Invalid result status or missing evidence: " + r.index);
    if (r.elapsedMs === null ? r.status !== "setup_failed" : !Number.isFinite(r.elapsedMs) || r.elapsedMs < 0) throw new Error("Invalid elapsedMs: " + r.index);
    if (!r.checks || typeof r.checks !== "object" || Array.isArray(r.checks) || Object.values(r.checks).some(value => typeof value !== "boolean")) throw new Error("Invalid checks: " + r.index);
    if (r.status === "verified" && (r.elapsedMs === null || r.elapsedMs <= 0 || r.elapsedMs > plan.definition.timeoutMs || plan.definition.requiredChecks.some(check => r.checks[check] !== true))) {
      throw new Error("Verified result lacks required checks or exceeded its deadline: " + r.index);
    }
    if (r.featureUsed !== undefined && typeof r.featureUsed !== "boolean") throw new Error("Invalid featureUsed: " + r.index);
    if (r.metrics !== undefined && (!r.metrics || typeof r.metrics !== "object" || Array.isArray(r.metrics) || Object.entries(r.metrics).some(([name, value]) => !metricNames.includes(name as typeof metricNames[number]) || typeof value !== "number" || !Number.isFinite(value) || value < 0))) {
      throw new Error("Invalid metrics: " + r.index);
    }
    rows.push({ ...r, ...trial });
  }
  const [before, after] = plan.definition.arms.map(a => a.id);
  const pairs = [...new Set(plan.schedule.map(t => t.pair))].map(pair => {
    const scheduled = plan.schedule.filter(t => t.pair === pair);
    const a = rows.find(r => r.pair === pair && r.arm === before), b = rows.find(r => r.pair === pair && r.arm === after);
    const bothVerified = a?.status === "verified" && b?.status === "verified";
    return { pair, case: scheduled[0].case, firstArm: scheduled[0].arm, beforeStatus: a?.status ?? "not_run", afterStatus: b?.status ?? "not_run", bothVerified, deltaMs: bothVerified ? b.elapsedMs! - a.elapsedMs! : null, reductionPercent: bothVerified ? 100 * (1 - b.elapsedMs! / a.elapsedMs!) : null, logSpeedup: bothVerified ? Math.log(a.elapsedMs! / b.elapsedMs!) : null };
  });
  const complete = pairs.filter(p => p.bothVerified);
  let seed = 20261115;
  const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
  const strata = plan.definition.cases.map(c => complete.filter(p => p.case === c.id));
  const bootstrap: number[] = [];
  if (strata.every(s => s.length >= 2)) {
    for (let i = 0; i < 10000; i++) {
      const samples = strata.flatMap(s => s.map(() => s[Math.floor(random() * s.length)].logSpeedup!));
      bootstrap.push(Math.exp(mean(samples)!));
    }
    bootstrap.sort((a, b) => a - b);
  }
  const summary = {
    planSha256: payload.planSha256, question: plan.definition.question,
    planned: plan.schedule.length, recorded: rows.length, notRun: plan.schedule.length - rows.length,
    arms: Object.fromEntries(plan.definition.arms.map(a => [a.id, aggregate(rows.filter(r => r.arm === a.id), plan.schedule.filter(t => t.arm === a.id).length)])),
    cases: Object.fromEntries(plan.definition.cases.map(c => [c.id, Object.fromEntries(plan.definition.arms.map(a => [a.id, aggregate(rows.filter(r => r.arm === a.id && r.case === c.id), plan.schedule.filter(t => t.arm === a.id && t.case === c.id).length)]))])),
    paired: { complete: complete.length, excluded: pairs.length - complete.length, faster: complete.filter(p => p.deltaMs! < 0).length, slower: complete.filter(p => p.deltaMs! > 0).length, tied: complete.filter(p => p.deltaMs === 0).length, medianDeltaMs: median(complete.map(p => p.deltaMs!)), meanDeltaMs: mean(complete.map(p => p.deltaMs!)), medianReductionPercent: median(complete.map(p => p.reductionPercent!)), geometricSpeedup: complete.length ? Math.exp(mean(complete.map(p => p.logSpeedup!))!) : null, exploratoryBootstrap95Speedup: bootstrap.length ? [bootstrap[250], bootstrap[9750]] : null },
    orderByCase: Object.fromEntries(plan.definition.cases.map(c => [c.id, Object.fromEntries(plan.definition.arms.map(a => [a.id, pairs.filter(p => p.case === c.id && p.firstArm === a.id).length]))])),
    pairs, failures: rows.filter(r => r.status !== "verified"), cleanup: payload.cleanup,
  };
  const seconds = (ms: number | null) => ms === null ? "n/a" : (ms / 1000).toFixed(3) + " s";
  const lines = ["# Benchmark report", "", plan.definition.question, "", `Plan SHA-256: ${summary.planSha256}. Frozen identities, prompts and environment are in plan.json.`, "", `Recorded ${summary.recorded}/${summary.planned}; not run: ${summary.notRun}.`, "", "```diff"];
  for (const [index, arm] of plan.definition.arms.entries()) {
    const data = summary.arms[arm.id];
    lines.push(`${index ? "+" : "-"} ${arm.id}: ${data.verified}/${data.recorded} verified; ${data.notRun} not run; successful median ${seconds(data.successfulMedianMs)}`);
  }
  lines.push("```", "", `Successful pairs: ${complete.length}/${pairs.length}; second arm faster/slower/tied: ${summary.paired.faster}/${summary.paired.slower}/${summary.paired.tied}.`, `Median paired delta (second − first): ${seconds(summary.paired.medianDeltaMs)}.`, `Geometric speed ratio (first/second): ${summary.paired.geometricSpeedup?.toFixed(3) ?? "n/a"}×; exploratory 95% interval: ${summary.paired.exploratoryBootstrap95Speedup?.map(value => value.toFixed(3)).join("–") ?? "n/a"}.`, "");
  for (const c of plan.definition.cases) {
    lines.push(`**${c.id}**`, "", "```diff");
    for (const [index, arm] of plan.definition.arms.entries()) {
      const data = summary.cases[c.id][arm.id];
      lines.push(`${index ? "+" : "-"} ${arm.id}: ${data.verified}/${data.recorded} verified; successful median ${seconds(data.successfulMedianMs)}`);
    }
    lines.push("```", "");
  }
  for (const arm of plan.definition.arms) {
    const usage = summary.arms[arm.id].featureUsage;
    lines.push(`${arm.id} feature used: ${usage.used}/${usage.observed} observed trials; unknown: ${summary.arms[arm.id].recorded - usage.observed}.`);
  }
  lines.push("", "Completion medians include verified trials only. Failures remain in recorded denominators; unrun trials are shown separately. Paired latency excludes unsuccessful or incomplete pairs and is conditional on both arms succeeding.", "", "See summary.json for per-case results, statuses, order, observed metrics and feature adoption. Missing metrics are unknown, not zero; metric samples may differ. Report cost only when supported by recorded billing or explicit pricing evidence.", "", "The deterministic task-stratified bootstrap interval is exploratory, conditional on successful pairs and these cases. It requires at least two successful pairs in every case and does not model provider temporal correlation. Even repetitions balance first-arm counts within each case; odd repetitions differ by one. No automatic performance verdict or historical causal claim is made.", "", `Cleanup: ${payload.cleanup.status}. ${payload.cleanup.evidence}`, "");
  await writeFile(join(directory, "summary.json"), JSON.stringify(summary, null, 2) + "\n", { mode: 0o600 });
  await writeFile(join(directory, "report.md"), lines.join("\n"), { mode: 0o600 });
  console.log(join(directory, "report.md"));
}

if (import.meta.main) {
  const args = Bun.argv.slice(2);
  if (args.length === 1 && args[0] === "--help") console.log("Usage: bun .agents/skills/test/benchmark/report.ts <plan.json>\nReads adjacent results.json and writes summary.json and report.md outside the checkout. No provider or device calls.");
  else {
    if (args.length !== 1) throw new Error("Expected one plan.json path; use --help");
    await report(resolve(args[0]));
  }
}

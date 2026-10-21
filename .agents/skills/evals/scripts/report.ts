import type { RunRecord } from "./types.ts";

const passes = (runs: RunRecord[]) => runs.filter(run => run.status === "pass").length;
const percent = (runs: RunRecord[]) => runs.length ? Math.round(100 * passes(runs) / runs.length) : 0;

function flags(byVariant: RunRecord[][]): string[] {
  const all = byVariant.flat();
  const result: string[] = [];
  if (all.some(run => run.status === "error")) result.push("error");
  if (byVariant.some(runs => passes(runs) > 0 && passes(runs) < runs.length)) result.push("flaky");
  if (byVariant.length === 2) {
    const [baseline, candidate] = byVariant.map(percent) as [number, number];
    if (baseline === 100 && candidate === 100) result.push("saturated");
    else if (baseline === 0 && candidate === 0) result.push("both fail");
    else if (candidate < baseline) result.push("regression");
    else if (candidate > baseline) result.push("improvement");
  }
  return result;
}

export function summarize(runs: RunRecord[], variants: string[], repetitions: number): string {
  const ids = [...new Set(runs.map(run => run.case))];
  const rows = [["case", ...variants, "flags"], ...ids.map(id => {
    const byVariant = variants.map(variant => runs.filter(run => run.case === id && run.variant === variant));
    return [id, ...byVariant.map(group => `${passes(group)}/${group.length}`), flags(byVariant).join(", ")];
  })];
  const widths = rows[0]!.map((_, column) => Math.max(...rows.map(row => row[column]!.length)));
  const lines = rows.map(row => row.map((cell, column) => cell.padEnd(widths[column]!)).join("  ").trimEnd());
  const errors = runs.filter(run => run.status === "error");
  lines.push("");
  if (errors.length) lines.push(`Headline withheld: ${errors.length} errored run(s).`, ...errors.map(run => `  ${run.case} ${run.variant} #${run.repetition}: ${run.error}`));
  else for (const variant of variants) {
    const group = runs.filter(run => run.variant === variant);
    const mean = (key: "tokens" | "elapsedMs") => Math.round(group.reduce((total, run) => total + (run.metrics?.[key] ?? 0), 0) / group.length);
    lines.push(`${variant}: ${passes(group)}/${group.length} passed (${percent(group)}%), mean ${mean("tokens")} tokens, ${mean("elapsedMs")} ms`);
  }
  for (const run of runs.filter(run => run.status === "fail")) lines.push(`FAIL ${run.case} ${run.variant} #${run.repetition}: ${run.checks.filter(check => !check.passed).map(check => check.detail).join("; ")}`);
  if (repetitions === 1) lines.push("One repetition cannot establish stability.");
  return lines.join("\n");
}

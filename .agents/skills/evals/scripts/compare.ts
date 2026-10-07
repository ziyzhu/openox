import type { Report } from "./types.ts";

export function compare(baseline: Report, candidate: Report) {
  for (const report of [baseline, candidate]) {
    if (report.version !== 3 || report.mode !== "ox-cli-chat" || !Array.isArray(report.results) || !Array.isArray(report.plannedCases) || !report.plannedCases.length) throw new Error("Unsupported eval report");
    if (new Set(report.plannedCases).size !== report.plannedCases.length || report.results.some(result => !report.plannedCases.includes(result.id))) throw new Error("Invalid planned cohort");
    const keys = report.results.map(result => `${result.id}:${result.repetition}`);
    if (new Set(keys).size !== keys.length) throw new Error("Duplicate attempts in report");
  }
  const ids = [...new Set([...baseline.plannedCases, ...candidate.plannedCases])];
  return ids.map(id => {
    const before = baseline.results.filter(result => result.id === id);
    const after = candidate.results.filter(result => result.id === id);
    const modelChanged = baseline.provider !== candidate.provider || baseline.model !== candidate.model || JSON.stringify(baseline.catalog) !== JSON.stringify(candidate.catalog);
    const limitsChanged = baseline.limits.timeoutMs !== candidate.limits.timeoutMs || baseline.limits.repetitions !== candidate.limits.repetitions;
    const contextChanged = new Set([...before, ...after].map(result => result.contextHash)).size > 1;
    const comparable = !modelChanged && !limitsChanged && before.length > 0 && before.length === baseline.limits.repetitions && after.length === candidate.limits.repetitions
      && before.every(result => result.repetition >= 1 && result.repetition <= baseline.limits.repetitions && after.some(attempt => attempt.repetition === result.repetition))
      && [...before, ...after].every(result => result.contextHash && result.caseHash === before[0]!.caseHash && result.status !== "error");
    const rate = (results: typeof before) => results.length ? results.filter(result => result.status === "pass").length / results.length : null;
    const oldRate = rate(before);
    const newRate = rate(after);
    return {
      id, baseline: oldRate, candidate: newRate, attempts: [before.length, after.length],
      change: !comparable ? "not-comparable" : newRate! < oldRate! ? "regression" : newRate! > oldRate! ? "improvement" : "unchanged",
      modelChanged, limitsChanged, contextChanged,
    };
  });
}

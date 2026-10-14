import type { Report } from "./types.ts";

export function compare(baseline: Report, candidate: Report) {
  for (const report of [baseline, candidate]) {
    if (report.version !== 4 || !["ox-cli-chat", "stubbed-ox"].includes(report.mode) || !Array.isArray(report.results) || !Array.isArray(report.plannedCases) || !report.plannedCases.length || !report.fixtureHash) throw new Error("Unsupported eval report");
    if (new Set(report.plannedCases).size !== report.plannedCases.length || report.results.some(result => !report.plannedCases.includes(result.id))) throw new Error("Invalid planned cohort");
    const keys = report.results.map(result => `${result.id}:${result.repetition}`);
    if (new Set(keys).size !== keys.length) throw new Error("Duplicate attempts in report");
    if (!Number.isInteger(report.limits?.repetitions) || report.limits.repetitions < 1 || report.limits.repetitions > 20
      || report.results.some(result => !Number.isInteger(result.repetition) || result.repetition < 1 || result.repetition > report.limits.repetitions || !["prepared", "missing"].includes(result.fixture)
        || !["pass", "fail", "blocked", "unverified", "error"].includes(result.status) || !["pending", "pass", "fail"].includes(result.review?.status))) throw new Error("Invalid attempt state or repetition");
    if (report.results.some(result => result.status === "pass" && (result.review?.status !== "pass" || !result.review.note?.trim() || !result.checks.length || result.checks.some(check => !check.passed) || !result.contextHash || result.response?.errors.length || result.response?.blocked))) throw new Error("Passing report lacks reviewed automatic evidence");
  }
  const ids = [...new Set([...baseline.plannedCases, ...candidate.plannedCases])];
  return ids.map(id => {
    const before = baseline.results.filter(result => result.id === id);
    const after = candidate.results.filter(result => result.id === id);
    const modelChanged = baseline.provider !== candidate.provider || baseline.model !== candidate.model || JSON.stringify(baseline.catalog) !== JSON.stringify(candidate.catalog);
    const limitsChanged = baseline.limits.timeoutMs !== candidate.limits.timeoutMs || baseline.limits.repetitions !== candidate.limits.repetitions || JSON.stringify(baseline.authorization) !== JSON.stringify(candidate.authorization);
    const fixtureChanged = baseline.fixtureHash !== candidate.fixtureHash;
    const contextChanged = new Set([...before, ...after].map(result => result.contextHash)).size > 1;
    const comparable = baseline.mode === candidate.mode && !modelChanged && !limitsChanged && !fixtureChanged && before.length > 0 && before.length === baseline.limits.repetitions && after.length === candidate.limits.repetitions
      && before.every(result => result.repetition >= 1 && result.repetition <= baseline.limits.repetitions && after.some(attempt => attempt.repetition === result.repetition))
      && [...before, ...after].every(result => result.contextHash && result.caseHash === before[0]!.caseHash && ["pass", "fail"].includes(result.status));
    const rate = (results: typeof before) => results.length ? results.filter(result => result.status === "pass").length / results.length : null;
    const oldRate = rate(before);
    const newRate = rate(after);
    return {
      id, baseline: oldRate, candidate: newRate, attempts: [before.length, after.length],
      change: !comparable ? "not-comparable" : newRate! < oldRate! ? "regression" : newRate! > oldRate! ? "improvement" : "unchanged",
      modelChanged, limitsChanged, fixtureChanged, contextChanged,
    };
  });
}

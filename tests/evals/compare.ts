import type { Report } from "./types.ts";

export function compare(baseline: Report, candidate: Report) {
  for (const report of [baseline, candidate]) {
    if (report.version !== 1 || report.mode !== "production-agent-fixture-tools" || !Array.isArray(report.results) || !report.results.length) throw new Error("Unsupported or empty eval report");
    const keys = report.results.map(result => `${result.id}:${result.repetition}`);
    if (new Set(keys).size !== keys.length) throw new Error("Duplicate attempts in report");
  }
  const ids = [...new Set([...baseline.results, ...candidate.results].map(result => result.id))];
  return ids.map(id => {
    const before = baseline.results.filter(result => result.id === id);
    const after = candidate.results.filter(result => result.id === id);
    const comparable = before.length > 0 && after.length === before.length && [...before, ...after].every(result => result.caseHash === before[0]!.caseHash && result.status !== "error");
    const rate = (results: typeof before) => results.length ? results.filter(result => result.status === "pass").length / results.length : null;
    const oldRate = rate(before);
    const newRate = rate(after);
    return {
      id, baseline: oldRate, candidate: newRate, attempts: [before.length, after.length],
      change: !comparable ? "not-comparable" : newRate! < oldRate! ? "regression" : newRate! > oldRate! ? "improvement" : "unchanged",
      modelChanged: baseline.provider !== candidate.provider || baseline.model !== candidate.model,
      contextChanged: new Set([...before, ...after].map(result => result.contextHash)).size > 1,
    };
  });
}

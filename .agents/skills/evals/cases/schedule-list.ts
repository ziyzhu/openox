import { called, mentions, only } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Are any of my schedules having problems?",
  checks: run => [called(run, "ox.schedule.list"), only(run, ["ox.schedule.list"]), mentions(run, "Weekly review"), { detail: "Reports the failed run", passed: /fail|unavailable|error/i.test(run.answer) }],
} satisfies EvalCase;

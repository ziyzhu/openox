import { called, mentions, only } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "What service repositories are enabled?",
  checks: run => [called(run, "ox.repository.list"), only(run, ["ox.repository.list", "ox.repository.conflicts"]), mentions(run, "Built-in", "Local")],
} satisfies EvalCase;

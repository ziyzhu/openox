import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Explain the difference between a model provider and an AI website in plain language. This is just a conceptual question, not a setup request.",
  checks: run => [readResource(run, "skills/evolve/SKILL.md", false)],
} satisfies EvalCase;

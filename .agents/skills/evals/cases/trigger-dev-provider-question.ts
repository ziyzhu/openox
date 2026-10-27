import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "What does temperature mean in a model API? Explain briefly; I don't want to change any provider settings.",
  checks: run => [readResource(run, "skills/evolve/SKILL.md", false)],
} satisfies EvalCase;

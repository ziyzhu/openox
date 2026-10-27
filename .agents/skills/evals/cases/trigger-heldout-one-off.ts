import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Turn these notes into a weekly review just this once: shipped account search; waiting on legal; next week finish onboarding. Don't create a reusable workflow or save anything.",
  checks: run => [readResource(run, "skills/evolve/SKILL.md", false)],
} satisfies EvalCase;

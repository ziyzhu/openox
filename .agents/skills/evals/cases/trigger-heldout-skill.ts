import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Make a reusable weekly-review workflow: use notes I supply each time, group completed work and blockers, and return a concise next-week plan. Don't schedule it or save personal details as instructions.",
  checks: run => [readResource(run, "skills/evolve/SKILL.md"), readResource(run, "skills/evolve/references/skills.md"), readResource(run, "skills/evolve/references/web-service.md", false)],
} satisfies EvalCase;

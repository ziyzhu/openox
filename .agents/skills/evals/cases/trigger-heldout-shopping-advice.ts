import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "I'm comparing two gym plans: $40 monthly with no commitment or $360 yearly paid up front. Explain the financial trade-off and what cancellation terms to ask about. No purchase yet.",
  checks: run => [readResource(run, "skills/checkout/SKILL.md", false)],
} satisfies EvalCase;

import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "One ticket option is $20 with free cancellation, the other is $16 nonrefundable. Compare them in a few sentences. Don't book or purchase anything.",
  checks: run => [readResource(run, "skills/checkout/SKILL.md", false)],
} satisfies EvalCase;

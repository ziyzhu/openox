import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Buy two standard adult tickets for tomorrow at https://museum.example. Bring me to the final price and payment page so I can review and pay myself.",
  checks: run => [readResource(run, "skills/checkout/SKILL.md")],
} satisfies EvalCase;

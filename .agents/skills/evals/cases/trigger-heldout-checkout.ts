import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Reserve a refundable double room for November 10–12 through https://hotel.example and prepare checkout. I'll review the cancellation terms and enter payment myself.",
  checks: run => [readResource(run, "skills/checkout/SKILL.md")],
} satisfies EvalCase;

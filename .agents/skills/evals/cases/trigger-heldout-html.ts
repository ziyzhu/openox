import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Build a little interactive break-even calculator I can use here: editable fixed cost, price per item, and cost per item, with a clear result and reset. Label it as a hypothetical calculation.",
  checks: run => [readResource(run, "skills/visualize/SKILL.md"), readResource(run, "skills/visualize/references/html.md")],
} satisfies EvalCase;

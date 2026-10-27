import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Draw a sequence diagram of an app sending an invoice to a server, the server charging through a payment provider, and the app receiving confirmation. Just a diagram, no interactive app.",
  checks: run => [readResource(run, "skills/visualize/SKILL.md"), readResource(run, "skills/visualize/references/html.md", false)],
} satisfies EvalCase;

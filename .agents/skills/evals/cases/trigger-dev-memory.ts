import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Bring the durable preferences ChatGPT knows about me into this Ox Profile. Let me review the proposed memory changes before anything is saved.",
  checks: run => [readResource(run, "skills/import-memory/SKILL.md")],
} satisfies EvalCase;

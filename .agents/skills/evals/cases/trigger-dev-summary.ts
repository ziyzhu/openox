import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Summarize this conversation excerpt: Me: Let's meet Tuesday. Assistant: Tuesday at 10 works. Me: Great, send the agenda Monday. I only need the summary, not a memory update.",
  checks: run => [readResource(run, "skills/import-memory/SKILL.md", false)],
} satisfies EvalCase;

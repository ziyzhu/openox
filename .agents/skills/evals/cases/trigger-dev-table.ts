import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Put these subscription prices in a small table in your reply: Basic $5/month, Plus $12/month, Team $20/month. I don't need a chart or file.",
  checks: run => [readResource(run, "skills/visualize/SKILL.md", false)],
} satisfies EvalCase;

import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "List three practical checks before I submit a reimbursement form. Keep it as plain bullets in this reply, not a diagram or app.",
  checks: run => [readResource(run, "skills/visualize/SKILL.md", false)],
} satisfies EvalCase;

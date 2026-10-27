import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "What's the difference between exporting an AI app's full chat history and copying a summary of its saved memory? Explain the trade-offs; don't retrieve or save anything.",
  checks: run => [readResource(run, "skills/import-memory/SKILL.md", false)],
} satisfies EvalCase;

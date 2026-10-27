import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Claude already knows my work preferences and ongoing projects. Can you bring that useful context over so Ox remembers it too? Show me what you'd merge first.",
  checks: run => [readResource(run, "skills/import-memory/SKILL.md")],
} satisfies EvalCase;

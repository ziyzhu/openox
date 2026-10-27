import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Create a reusable Ox integration for the inventory HTTP API documented at https://inventory.example/docs. It uses an API key. Start by checking existing support and the official contract; don't guess endpoints or ask me to paste a key.",
  checks: run => [readResource(run, "skills/evolve/SKILL.md"), readResource(run, "skills/evolve/references/web-service.md", false)],
} satisfies EvalCase;

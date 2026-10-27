import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Add our team's custom OpenAI-compatible endpoint https://inference.example/v1 as a model provider. Keep my current model and credentials unchanged; tell me if native support is missing.",
  checks: run => [
    { detail: "Consulted the provider workflow", passed: readResource(run, "skills/manage-providers/SKILL.md").passed || (readResource(run, "skills/evolve/SKILL.md").passed && readResource(run, "skills/evolve/references/providers.md").passed) },
    readResource(run, "skills/evolve/references/web-service.md", false),
  ],
} satisfies EvalCase;

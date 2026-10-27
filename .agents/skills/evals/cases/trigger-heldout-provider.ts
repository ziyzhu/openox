import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Our provider's model picker seems outdated. Refresh its available model list from official evidence, preserving the endpoint, account, pinned settings, and selected conversation model.",
  checks: run => [
    { detail: "Consulted the provider workflow", passed: readResource(run, "skills/manage-providers/SKILL.md").passed || (readResource(run, "skills/evolve/SKILL.md").passed && readResource(run, "skills/evolve/references/providers.md").passed) },
    readResource(run, "skills/evolve/references/web-service.md", false),
  ],
} satisfies EvalCase;

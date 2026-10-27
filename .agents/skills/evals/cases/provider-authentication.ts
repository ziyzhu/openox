import { readResource, succeeded } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Connect my existing QA API provider account so I can enter my API key securely. Don't change its definition or my selected model, and don't run billable inference.",
  stubs: { functions: {
    "ox.provider.authenticate": [{ args: { id: "qa-api" }, result: { id: "qa-api", status: "credential-stored" } }],
  } },
  checks: run => [
    { detail: "Consulted provider guidance", passed: readResource(run, "skills/manage-providers/SKILL.md").passed || readResource(run, "skills/evolve/references/providers.md").passed },
    { detail: "Used secure provider authentication", passed: succeeded(run, "ox.provider.authenticate").some(call => call.args.id === "qa-api") },
    { detail: "Preserved configuration, credentials, and selected model outside the requested authentication", passed: !run.calls.some(call => ["ox.provider.save", "ox.provider.delete", "ox.provider.deauthenticate", "ox.provider.generate", "ox.secret.add", "ox.app.setDefaultModel", "ox.app.setModel", "ox.conversation.setModel"].includes(call.name)) },
    { detail: "Did not request an API key in chat", passed: !/paste (?:your |the )?(?:api )?key|send me (?:your |the )?(?:api )?key/i.test(run.answer) },
  ],
} satisfies EvalCase;

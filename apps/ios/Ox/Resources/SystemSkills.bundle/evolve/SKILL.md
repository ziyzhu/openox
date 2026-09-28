---
name: evolve
description: Create, extend, repair, and verify Local web and API services, including model-generation actions and website tasks with no suitable service. Use existing functions directly for connections, repositories, and ordinary service use.
---

# Evolve

Build useful service capabilities from observed behavior. Keep discovery, exploration, implementation, live verification, and Save in one workflow. Use existing services normally when their definitions already meet the request.

Evolve a service when a requested capability is missing, an existing action is confirmed broken, or Ox completes a repeatable workflow without a suitable service action. Add or repair the smallest action supported by the observed workflow. Distinguish service defects from sign-in, human verification, rate limiting, missing resources, and temporary website failures. A general public-information question alone does not call for a service.

Read `skills/evolve/references/web-service.md` for Local web-service authoring or substantive verification, including Browser fulfillment when successful discovery finds no suitable service or action for a website task. Inspection, copying, attachment changes, history, and straightforward deletion need no authoring reference.

For web-service authoring, read `skills/evolve/references/helpers.js` only when a helper is needed. It is copyable source for `actions.js`, not an installed library, module, or runtime import.

Read `skills/evolve/references/api-service.md` for direct HTTP API services with API-key, Basic, Bearer, or OAuth authentication.

Read `skills/evolve/references/model-service.md` when adding or editing standard model-generation Actions on a web service. Model providers use the same copy-to-Local, conflict resolution, validation, and Save workflow as other services.

## Ownership and safeguards

- Local API source at `services/api/<id>/` is editable and uses Host-managed authentication.
- Local web source at `services/web/<domain>/` is editable. Bundled source and Development/Remote manifests are read-only; copy eligible services with `ox.service.copy` before editing. iOS services are not authorable.
- If a copy already exists or the wrong source resolves, use `ox.repository.conflicts` and `ox.repository.resolve` to select the intended source without replacing Local work.
- Discover with `ox.service.find` and `ox.service.listAttached`; inspect with `ox.service.inspect` and `ox.fs.read`.
- Set `requireApproval: false` for read-only actions by default. Require approval for external mutations. Preserve runtime authentication and attachment approval gates.
- Do not change the manifest schema. Preserve runtime approval gates and unrelated Local changes. Inspect Local status and diff before Save, revert, restore, or deletion; keep abandoned work recoverable.
- Present Local persistence as **Save**, for example `Save Outlook service`. Keep Git and revision mechanics internal unless the user asks or recovery requires them.

## Share a verified service

Share only a saved, verified Local version. Run `ox.service.validate` for every selected service, inspect `ox.repository.git.status` and `ox.repository.git.diff`, then save the intended Local changes with `ox.repository.git.commit`. Use the returned full commit hash with `ox.repository.propose({ target: "openox", commitHash, services, title, body, status, purpose })`. `services` contains Local service domains, and `status` is explicitly `draft` or `open`.

The proposal action asks for approval, may ask the user to authorize the target provider, uploads the selected service files and target manifest through the provider API, and returns the change-request URL. It does not publish uncommitted work or clone the target repository. Never put credentials, session data, raw captures, or machine-specific files in a proposal.

Repositories can also share independent skills under root `skills/<name>/`. Read `skills/manage-skills/SKILL.md` when creating or publishing a reusable workflow. Services do not contain nested skills.

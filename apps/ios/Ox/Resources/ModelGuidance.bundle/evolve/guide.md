# Evolve

Build useful service capabilities from observed behavior. Keep discovery, exploration, implementation, live verification, and Save in one workflow. Use existing services normally when their definitions already meet the request.

Evolve a service when a requested capability is missing, an existing action is confirmed broken, or observed behavior reveals a stable way to make the service more complete, reliable, or efficient. When Ox notices a concrete improvement opportunity while fulfilling a request, implement and verify the smallest useful improvement within that request's scope, even when the user did not explicitly ask to evolve the service. Repeated workarounds, unnecessary post-processing or orchestration, unclear capability descriptions, and observed reliability or efficiency improvements are useful signals. Leave an action unchanged when there is no material improvement. Distinguish service defects from sign-in, human verification, rate limiting, missing resources, and temporary website or API failures. A general public-information question alone does not call for a service.

Fulfill the original request first, then run at most one bounded improvement pass. Optional improvement must not cause another user prompt, approval, sign-in, or external effect, and new user input takes priority. Never repeat a completed mutation for verification. If improvement requires expanded scope or user input, explain the opportunity instead of proceeding. Save verified improvements only when the Local repository was clean before this work began; otherwise leave them unsaved and report the limitation.

Read `guidance/evolve/references/web-service.md` for Local web-service authoring or substantive verification, including Browser fulfillment when successful discovery finds no suitable service or action for a website task. Inspection, copying, attachment changes, history, and straightforward deletion need no authoring reference.

For web-service authoring, read `guidance/evolve/references/helpers.js` only when a helper is needed. It is copyable source for `actions.js`, not an installed library, module, or runtime import.

Read `guidance/evolve/references/api-service.md` for direct HTTP API services with API-key, Basic, Bearer, or OAuth authentication.

Read `guidance/evolve/references/model-service.md` when adding or editing standard model-generation Actions on a web service. Model providers use the same copy-to-Local, conflict resolution, validation, and Save workflow as other services.

## Ownership and safeguards

- Local API source at `services/api/<id>/` is editable and uses Host-managed authentication.
- Local web source at `services/web/<domain>/` is editable. Bundled source and Development/Remote manifests are read-only; copy eligible services with `ox.service.copy` before editing. iOS services are not authorable.
- If a copy already exists or the wrong source resolves, use `ox.repository.conflicts` and `ox.repository.resolve` to select the intended source without replacing Local work.
- Discover with `ox.service.find` and `ox.service.listAttached`; inspect with `ox.service.inspect` and `ox.fs.read`.
- Set `requireApproval: false` for read-only actions by default. Require approval for external mutations. Preserve runtime authentication and attachment approval gates.
- Do not change the manifest schema. Preserve runtime approval gates and unrelated Local changes. Inspect Local status and diff before Save, revert, restore, or deletion; keep abandoned work recoverable.
- Inspect complete Local repository status before creating, copying, or editing a service, and remember whether it was already dirty. If it had any uncommitted changes, skip automatic Save even after verification; do not commit, revert, or overwrite the pre-existing changes. Report that the improvement remains unsaved. Otherwise, Save verified Local changes after reviewing status and diff without asking for a separate Save confirmation. Present the operation as **Save**, for example `Save Outlook service`. Keep Git and revision mechanics internal unless the user asks or recovery requires them. Honor any runtime Action policy gate.
- In user-facing plans, progress, and results, describe what Ox can do, what the user needs to do, and what remains uncertain in everyday language. Keep action IDs, service domains, base URLs, schemas, source files, captures, and repository mechanics internal unless the user asks for technical details or a specific detail is needed for a decision or recovery.

Repositories can also store independent skills under root `skills/<name>/`. Read `guidance/manage-skills/guide.md` when creating or editing a reusable workflow. Services do not contain nested skills.

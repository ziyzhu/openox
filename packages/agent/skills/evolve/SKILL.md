---
name: evolve
description: "Create, extend, repair, or verify Local web and API services, including model-generation actions and improvements discovered during ordinary use."
---

# Evolve

Use this guide for service exploration, authoring, repair, and live verification. The system prompt defines when to evolve services and the completion requirements for verification and attachment.

Evolve a service when a requested capability is missing, an existing action is confirmed broken, or observed behavior reveals a stable way to make the service more complete, reliable, or efficient. When Ox notices a concrete improvement opportunity while fulfilling a request, implement and verify the smallest useful improvement within that request's scope, even when the user did not explicitly ask to evolve the service. Repeated workarounds, unnecessary post-processing or orchestration, unclear capability descriptions, and observed reliability or efficiency improvements are useful signals. Leave an action unchanged when there is no material improvement. Distinguish service defects from sign-in, human verification, rate limiting, missing resources, and temporary website or API failures. A general public-information question alone does not call for a service.

Build or repair capabilities needed to fulfill the original request, then complete it. Proactively improve existing actions when observed behavior reveals a material improvement within the request's scope. For optional improvements, fulfill the original request first, then run at most one bounded improvement pass. Optional improvement must not cause another user prompt, approval, sign-in, or external effect, and new user input takes priority. Never repeat a completed mutation for verification. If improvement requires expanded scope or user input, explain the opportunity instead of proceeding. Preserve unrelated Local source. Edits persist immediately; report incomplete or unverified drafts accurately.

When a website sign-in handoff returns `completion: "acknowledged"`, the user says sign-in is finished but access remains unverified. Resume the original request without reopening sign-in. Treat the mismatch as a concrete detector-repair opportunity: inspect fresh read-only session evidence, distinguish an actual signed-out session from a defective probe, and repair only an evidenced defect. The Host allows one authenticated read in this caller for up to two minutes; it is evidence gathering, not verified authentication or permission for mutations. Do not repeatedly request acknowledgment. Follow the web reference to verify the repair; disclose unresolved access or verification limits. API credentials, OAuth callbacks, and native OS grants cannot be replaced by acknowledgment. Native permission/runtime defects require an app fix rather than service authoring.

Read `references/web-service.md` for Local web-service authoring or substantive verification, including Browser fulfillment when successful discovery finds no suitable service or action for a website task. Inspection, copying, attachment changes, and straightforward deletion need no authoring reference.

Every newly authored customer-facing service, including API services, requires a high-quality favicon. Follow Choose a favicon in `references/web-service.md` as part of final service verification; repair missing or broken icons when updating services. Report incomplete icon verification explicitly.

For web-service authoring, read `references/helpers.js` only when a helper is needed. It is copyable source for `actions.js`, not an installed library, module, or runtime import.

Read `references/api-service.md` for direct HTTP API services with API-key, Basic, Bearer, or OAuth authentication.

Read `references/model-service.md` when adding or editing website conversation Actions. Websites remain services, not Ox model providers; never build a browser bridge for the agent loop. API-backed providers are managed through `skills/manage-providers/SKILL.md`.

## Efficient execution

The workflow steps are checks, not separate model turns. For a simple service, batch predictable work into a few executions and return to reasoning only when evidence, a failure, or a human decision changes the next step. Do not sacrifice verification to meet a turn target.

1. Read the applicable authoring reference, discover existing coverage, and inspect repository enablement and relevant Local source together when their contracts are known. Reuse results within this run unless intervening changes invalidate them.
2. Gather the smallest sufficient website or official API evidence for the requested actions. Discover the product favicon alongside this work. Batch independent reads and return only the fields needed to implement or decide.
3. Once evidence supports implementation, create or copy, read the generated files, write the complete manifest and handlers, validate, and attach in one execution when budgets allow. Await each dependent operation and stop on failure; never attach an invalid draft. Runtime approval gates still apply.
4. Inspect all needed action contracts together. Then batch bounded read-only verification, final source reads, and attachment confirmation. Verify each changed handler; exercise pagination, authentication, concurrency, and handoffs only when the service exposes or depends on them. Keep mutations approval-gated and never repeat completed effects.
5. Review the returned evidence and report completion. Local edits persist immediately; no separate Save step is needed. Repair only evidenced failures and rerun affected checks.

Use these batches for both web and API authoring. Keep sequential writes and dependent reads awaited, parallelize only independent reads, and respect execution time and output limits. Do not refetch unchanged contracts or source merely because another numbered workflow step mentions them. Fresh-state requirements for authentication, concurrent edits, and final source review still apply.

## Ownership and safeguards

- Before mutating Local services or repository skills, inspect `ox.repository.list`. Local is always enabled; if it is not ready, report the state instead of trying another domain or deleting and recreating drafts.
- Local API source at `services/api/<id>/` is editable and uses Host-managed authentication.
- Local web source at `services/web/<domain>/` is editable. Bundled source and Development/Remote manifests are read-only; copy eligible services with `ox.service.copy` before editing. iOS services are not authorable.
- If a copy already exists or the wrong source resolves, use `ox.repository.conflicts` and `ox.repository.resolve` to select the intended source without replacing Local work.
- Discover with `ox.service.find` and `ox.service.listAttached`; inspect with `ox.service.inspect` and `ox.fs.read`.
- Set `requireApproval: false` for read-only actions by default. Require approval for external mutations. Preserve runtime authentication and attachment approval gates.
- Do not change the manifest schema. Preserve runtime approval gates and unrelated Local changes. Read existing source before editing or deletion and keep abandoned work recoverable.
- Local file changes persist immediately, including incomplete drafts. There is no separate Save step or built-in version history. Validate and verify the service before reporting it ready; do not promise automatic rollback. Honor any runtime Action policy gate.
- In user-facing plans, progress, and results, describe what Ox can do, what the user needs to do, and what remains uncertain in everyday language. Keep action IDs, service domains, base URLs, schemas, source files, captures, and repository mechanics internal unless the user asks for technical details or a specific detail is needed for a decision or recovery.

Repositories can also store independent skills under root `skills/<name>/`. Read `skills/manage-skills/SKILL.md` when creating or editing a reusable workflow. Services do not contain nested skills.

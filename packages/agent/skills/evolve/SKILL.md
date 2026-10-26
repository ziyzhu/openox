---
name: evolve
description: "Create, connect, extend, repair, or verify services and reusable skills when requested or needed to complete the task."
---

# Evolve

Use this guide when the user requests service or skill authoring, connection, repair, or verification, or when a missing or confirmed broken capability must be built or repaired to complete the task. Services provide capabilities; skills compose reusable workflows. Read `references/skills.md` for skill creation, improvement, ownership, and verification. Continue predictable work without proposal checkpoints. Pause only for consequential missing decisions, runtime approvals, human-only steps, or concrete blockers, then resume after successful handoffs.

Fulfill website tasks through service actions. Reuse suitable existing actions; when coverage is missing or confirmed broken, build or repair the smallest capability needed, then invoke it to complete the request. Use Browser only to observe websites and develop service actions, not as a direct fulfillment or fallback path. If authoring is blocked, report the concrete blocker. Distinguish service defects from sign-in, human verification, rate limiting, missing resources, and temporary website or API failures.

After authoring, validate the final draft, attach or reload it with `ox.service.attach`, inspect the action contracts, verify changed actions through live invocation, and confirm attachment with `ox.service.listAttached`. Then complete the original request. Never repeat a completed mutation for verification. Stop when the requested outcome is complete; leave unrelated improvements alone. Preserve unrelated Local source. Edits persist immediately with no separate Save step or built-in version history; report incomplete or unverified drafts accurately.

When a website sign-in handoff returns `completion: "acknowledged"`, the user says sign-in is finished but access remains unverified. Resume the original request without reopening sign-in. Treat the mismatch as a concrete detector-repair opportunity: inspect fresh read-only session evidence, distinguish an actual signed-out session from a defective probe, and repair only an evidenced defect. The Host allows one authenticated read in this caller for up to two minutes; it is evidence gathering, not verified authentication or permission for mutations. Do not repeatedly request acknowledgment. Follow the web reference to verify the repair; disclose unresolved access or verification limits. API credentials, OAuth callbacks, and native OS grants cannot be replaced by acknowledgment. Native permission/runtime defects require an app fix rather than service authoring.

Read `references/web-service.md` before Browser exploration, Local web-service authoring, or substantive verification. Source inspection, copying, attachment changes, and straightforward deletion need no authoring reference.

Before attaching or reloading a newly authored customer-facing service, including API services, set a high-quality `faviconUrl` that passes Choose a favicon in `references/web-service.md`. Repair missing or broken icons before attaching updates. If no candidate passes, preserve the draft, do not attach or reload it, and report the favicon blocker. Manifest validation alone does not verify image loading.

For web-service authoring, read `references/helpers.js` only when a helper is needed. It is copyable source for `actions.js`, not an installed library, module, or runtime import.

For MCP or API connection requests, `ox.service.find` searches existing services in enabled repositories, not the public internet. Use a supplied endpoint or official documentation directly. When no existing service fits and the endpoint is unknown, use `ox.web.search` and fetch official documentation to discover remote MCP endpoints or API access; an empty repository search does not establish that no integration exists. Verify endpoint URLs, transport, and authentication from official evidence rather than guessing.

Connect a remote MCP server with `ox.service.create({ purpose, kind: "mcp", endpoint, transport? })`; omit domain and use the returned domain to inspect, attach, and verify its tools. MCP creation saves immediately and may request sign-in. Do not author API handlers for an MCP server or assume a local stdio server has a remote HTTPS endpoint. If only local installation is documented, report that limitation and investigate a documented API alternative within the request.

Read `references/api-service.md` for direct HTTP API services with API-key, Basic, Bearer, or OAuth authentication.

Read `references/model-service.md` when adding or editing website conversation Actions. Websites remain services, not Ox model providers; never build a browser bridge for the agent loop. API-backed providers are managed through `skills/manage-providers/SKILL.md`.

## Efficient execution

The workflow steps are checks, not separate model turns. For a simple service, batch predictable work into a few executions and return to reasoning only when evidence, a failure, or a human decision changes the next step. Do not sacrifice verification to meet a turn target.

1. Read the applicable authoring reference, discover existing coverage, and inspect repository enablement and relevant Local source together when their contracts are known. Reuse results within this run unless intervening changes invalidate them.
2. Gather the smallest sufficient website or official API evidence for the requested actions. Discover and preflight the product favicon alongside this work, before attachment. Batch independent reads and return only the fields needed to implement or decide.
3. Once evidence supports implementation, create or copy, read the generated files, write the complete manifest and handlers, validate, and attach in one execution when budgets allow. Await each dependent operation and stop on failure; never attach an invalid draft or one missing a verified product `faviconUrl`. Runtime approval gates still apply.
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

When authoring changes a service contract, repair affected skills within the requested scope. Create a new reusable workflow when requested or needed for the task. Read `references/skills.md`. Repositories store independent skills under root `skills/<name>/`; services do not contain nested skills.

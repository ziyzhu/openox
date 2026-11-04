---
name: evolve
description: "Use when creating, connecting, extending, repairing, auditing, or verifying services and reusable skills, repairing service validation failures after app updates or incompatible contract changes, or configuring and troubleshooting model providers and their model lists. Also use when a missing or confirmed broken capability prevents completing the request. Ordinary use of working services or configured models does not require this skill."
---

# Evolve

Build or repair the smallest capability needed, verify it, then complete the original request. Services provide capabilities; skills compose workflows; model providers run the agent through API transports. Continue predictable work without proposal checkpoints. Pause only for consequential missing decisions, runtime approvals, human-only steps, or concrete blockers. Stop when the requested outcome is complete.

Work inside Ox through awaited `ox.*` calls and the virtual filesystem. Do not assume a terminal, Node.js, package installation, or access to app source. Preserve unrelated work and the user's working accounts and model. Local edits persist immediately, including incomplete drafts; there is no separate Save step or built-in version history. Report drafts and unverified behavior accurately.

## Choose the workflow

Load only the references needed for this task. Paths are relative to this skill directory.

| Task | Read before implementation |
| --- | --- |
| Configure, connect, refresh, audit, restore, or repair a model provider or its models | `references/providers.md` |
| Explore a website to build or repair a service, repair web service validation failures, or substantively verify web handlers | `references/web-service.md` |
| Connect a direct HTTP API with Host-managed authentication or repair API service validation failures | `references/api-service.md` |
| Create, improve, copy, share, or verify a reusable skill | `references/skills.md` |
| Add or repair website conversation Actions | Web service reference, then `references/model-service.md` |
| Add or standardize a website's default search action | Web service reference, then `references/search.md` |
| Set or repair a customer-facing web or API service favicon | `references/service-icon.md` |

Source inspection, copying, attachment changes, and straightforward deletion need no service-authoring reference. Compare repository candidates read-only with `ox.repository.conflicts({ purpose, service, compare: true })`; complete file hashes establish exact copies without activating either source. Never use `ox.repository.resolve` to preview or compare files. Source resolution activates a candidate, `ox.service.attach` loads current source, and page reload refreshes a website document; these are distinct operations. Provider configuration does not require Browser exploration, a service favicon, or service attachment. An AI website is a service, never a model-provider transport; do not build a browser bridge for the agent loop.

For remote MCP connections, use the supplied endpoint or official documentation and check relevant saved definitions under `services/mcp/` with targeted `ox.fs.glob` lookups. Reuse a matching connection; missing saved source is not a capability limit. If necessary, use `ox.web.search` and fetch official documentation; verify endpoint, transport, and authentication rather than guessing. Create with `ox.service.create({ purpose, kind: "mcp", endpoint, transport? })`, omit domain, and use the returned domain to inspect, attach, and verify its tools. Creation saves immediately and may request login. Do not author API handlers for MCP or assume local stdio installation has a remote HTTPS endpoint. Report local-only limitations and investigate a documented API alternative within scope.

For service inventories and validation audits, use `ox.service.list` to enumerate selected sources, including invalid definitions and their errors. Use repository provenance to target Local repairs; do not validate every directory in the merged VFS as though it were Local. Repair needed invalid contracts, validate, reload with `ox.service.attach`, and retry the original action before returning to the task.

## Service authoring loop

Fulfill website tasks through service actions. Browser is for evidence and service development, not direct fulfillment or fallback. Distinguish a confirmed service defect from login, human verification, rate limiting, missing resources, and temporary failures. Failed discovery does not establish absence. If authoring is blocked, report the concrete blocker.

When evolving services, inspect and validate only the target service and dependencies needed for the current request. Audit unrelated Local drafts only when the user requests an inventory or validation audit. Use targeted source lookups and `ox.repository.conflicts` when source selection matters; inspect `ox.repository.list` when repository identity or readiness is unknown. Invalid source may be absent from the usable catalog, so do not infer absence from attachments or catalog counts. Validate complete affected Local drafts with `ox.service.validate` using their bare domains. For requested multi-service audits, catch each failure separately, retain its diagnostic, and continue; report inaccessible or truncated coverage rather than claiming every service passed.

Repair confirmed validation failures within the current request's scope, including incompatibilities introduced by app updates, through the applicable service reference. Read the affected source and current contracts, make the smallest compatible patch preserving intended behavior and unrelated Local work, then revalidate the whole draft until it passes or a concrete blocker remains. Use `ox.fs.edit` when an invalid manifest prevents `ox.service.update`. Do not delete actions merely to pass validation, replace intentional incomplete drafts, or repeat an unchanged failing check. Validation failures are source defects, not evidence that the user is signed out; legacy authentication-action errors follow the same repair loop. A different Built-in candidate does not authorize overwriting Local work or silently switching sources. Copy eligible read-only source before repair; report source that cannot be copied or edited as blocked.

Validation alone does not verify runtime behavior. Attach or reload services needed for the original request and exercise repaired handlers through their actual service actions, preserving approval and authentication gates. Do not attach unrelated services just to audit them. Report which repairs passed validation, which received live verification, and any remaining failures or incomplete drafts, then complete the original request. If repair requires a consequential source choice or cannot be verified, surface that decision or blocker instead of substituting indexed excerpts for the requested website action.

1. Start with the target domain from the request or public research. Check relevant source under `services/<kind>/<domain>/` with `ox.fs`, and inspect repository readiness. Reuse suitable source; missing coverage means build the needed service, not that the domain is unsupported. Local is always enabled; if not ready, report its state rather than deleting drafts or trying another domain. Copy eligible read-only services before editing; iOS services are not authorable. Resolve source conflicts through `ox.repository.conflicts` and `ox.repository.resolve` without replacing Local work.
2. Gather the smallest sufficient website or official API evidence. Preflight the product favicon alongside discovery, using the icon reference. A new or updated customer-facing web or API service must have a verified `faviconUrl` before attachment; if no candidate passes, preserve the draft and existing attachment and report the blocker.
3. Create or copy, read generated files, make one coherent patch, validate the complete draft with `ox.service.validate`, then attach or reload with `ox.service.attach`. Never attach invalid source. Preserve the manifest schema and unrelated changes. Reads normally use `requireApproval: false`; external mutations require approval. Authentication and attachment gates remain authoritative.
4. Inspect needed action contracts, invoke changed handlers on their actual execution pages, and inspect resulting state. Reuse complete contracts already returned by inspection. The attachment response and successful invocation establish attachment; use `ox.service.listAttached` only when attachment state remains uncertain. Exercise only applicable pagination, authentication, concurrency, and handoffs. Never repeat a completed mutation for verification; inspect uncertain effects read-only before considering a retry.
5. Review final source and evidence, repair affected skills within scope when contracts changed, and complete the original request. Describe outcomes, user steps, and limitations in everyday language; keep internal mechanics out of replies unless requested or necessary for a decision.

These are checks, not separate model turns. Batch predictable dependent operations in one execution, awaiting each and stopping on failure. Parallelize only independent reads, return compact evidence, and respect execution budgets. Reuse unchanged contracts and source within a run; re-read when authentication, concurrent edits, or final review requires fresh state. Do not trade verification for a turn target.

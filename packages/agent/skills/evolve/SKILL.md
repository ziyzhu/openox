---
name: evolve
description: "Use when creating, connecting, extending, repairing, or verifying services and reusable skills, or configuring and troubleshooting model providers and their model lists. Also use when a missing or confirmed broken capability prevents completing the request. Ordinary use of working services or configured models does not require this skill."
---

# Evolve

Build or repair the smallest capability needed, verify it, then complete the original request. Services provide capabilities; skills compose workflows; model providers run the agent through API transports. Continue predictable work without proposal checkpoints. Pause only for consequential missing decisions, runtime approvals, human-only steps, or concrete blockers. Stop when the requested outcome is complete.

Work inside Ox through awaited `ox.*` calls and the virtual filesystem. Do not assume a terminal, Node.js, package installation, or access to app source. Preserve unrelated work and the user's working accounts and model. Local edits persist immediately, including incomplete drafts; there is no separate Save step or built-in version history. Report drafts and unverified behavior accurately.

## Choose the workflow

Load only the references needed for this task. Paths are relative to this skill directory.

| Task | Read before implementation |
| --- | --- |
| Configure, connect, refresh, audit, restore, or repair a model provider or its models | `references/providers.md` |
| Explore a website to build or repair a service, or substantively verify web handlers | `references/web-service.md` |
| Connect a direct HTTP API with Host-managed authentication | `references/api-service.md` |
| Create, improve, copy, share, or verify a reusable skill | `references/skills.md` |
| Add or repair website conversation Actions | Web service reference, then `references/model-service.md` |
| Set or repair a customer-facing web or API service favicon | `references/service-icon.md` |

Source inspection, copying, attachment changes, and straightforward deletion need no service-authoring reference. Compare repository candidates read-only with `ox.repository.conflicts({ purpose, service, compare: true })`; complete file hashes establish exact copies without activating either source. Never use `ox.repository.resolve` to preview or compare files. Source resolution activates a candidate, `ox.service.attach` loads current source, and page reload refreshes a website document; these are distinct operations. Provider configuration does not require Browser exploration, a service favicon, or service attachment. An AI website is a service, never a model-provider transport; do not build a browser bridge for the agent loop.

For remote MCP connections, search existing services with `ox.service.find`, then use the supplied endpoint or official documentation. Repository search is not internet discovery. If necessary, use `ox.web.search` and fetch official documentation; verify endpoint, transport, and authentication rather than guessing. Create with `ox.service.create({ purpose, kind: "mcp", endpoint, transport? })`, omit domain, and use the returned domain to inspect, attach, and verify its tools. Creation saves immediately and may request sign-in. Do not author API handlers for MCP or assume local stdio installation has a remote HTTPS endpoint. Report local-only limitations and investigate a documented API alternative within scope.

## Service authoring loop

Fulfill website tasks through service actions. Browser is for evidence and service development, not direct fulfillment or fallback. Distinguish a confirmed service defect from sign-in, human verification, rate limiting, missing resources, and temporary failures. Failed discovery does not establish absence. If authoring is blocked, report the concrete blocker.

1. Discover existing coverage and inspect relevant source and repository readiness together. Local is always enabled; if not ready, report its state rather than deleting drafts or trying another domain. Copy eligible read-only services before editing; iOS services are not authorable. Resolve source conflicts through `ox.repository.conflicts` and `ox.repository.resolve` without replacing Local work.
2. Gather the smallest sufficient website or official API evidence. Preflight the product favicon alongside discovery, using the icon reference. A new or updated customer-facing web or API service must have a verified `faviconUrl` before attachment; if no candidate passes, preserve the draft and existing attachment and report the blocker.
3. Create or copy, read generated files, make one coherent patch, validate the complete draft with `ox.service.validate`, then attach or reload with `ox.service.attach`. Never attach invalid source. Preserve the manifest schema and unrelated changes. Reads normally use `requireApproval: false`; external mutations require approval. Authentication and attachment gates remain authoritative.
4. Inspect needed action contracts, invoke changed handlers on their actual execution pages, inspect resulting state, and confirm attachment with `ox.service.listAttached`. Exercise only applicable pagination, authentication, concurrency, and handoffs. Never repeat a completed mutation for verification; inspect uncertain effects read-only before considering a retry.
5. Review final source and evidence, repair affected skills within scope when contracts changed, and complete the original request. Describe outcomes, user steps, and limitations in everyday language; keep internal mechanics out of replies unless requested or necessary for a decision.

These are checks, not separate model turns. Batch predictable dependent operations in one execution, awaiting each and stopping on failure. Parallelize only independent reads, return compact evidence, and respect execution budgets. Reuse unchanged contracts and source within a run; re-read when authentication, concurrent edits, or final review requires fresh state. Do not trade verification for a turn target.

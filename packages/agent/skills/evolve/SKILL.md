---
name: evolve
description: "Use to create, connect, extend, repair, audit, or verify services and reusable skills; configure or troubleshoot model providers and models; or restore a missing or confirmed broken capability. Includes validation failures after app updates. Ordinary use of working services or configured models does not require this skill."
---

# Evolve

Build or repair the smallest capability needed, verify it, then complete the original request. Services provide capabilities; skills compose workflows; model providers run the agent through API transports. Continue predictable work without proposal checkpoints; pause for consequential missing decisions, approvals, human-only steps, or concrete blockers.

Use awaited `ox.*` calls and the virtual filesystem, not a terminal, Node.js, package installation, or app source. Preserve unrelated work, accounts, and the user's model. Local edits persist immediately, including incomplete drafts; there is no separate Save step or version history.

## Choose the workflow

Load only needed references; paths are relative to this skill directory.

| Task | Read before implementation |
| --- | --- |
| Configure, connect, refresh, audit, restore, or repair providers/models | `references/providers.md` |
| Build, repair, or substantively verify web handlers | `references/web-service.md` |
| Connect or repair direct HTTP APIs with Host-managed authentication | `references/api-service.md` |
| Create, improve, copy, share, or verify reusable skills | `references/skills.md` |
| Add or repair website conversation Actions | Web service reference, then `references/model-service.md` |
| Add or standardize default website search | Web service reference, then `references/search.md` |
| Set or repair a web/API service favicon | `references/service-icon.md` |

Inspection, copying, attachment changes, and straightforward deletion need no authoring reference. Compare sources read-only with `ox.repository.conflicts({ purpose, service, compare: true })`; complete hashes establish exact equality. `ox.repository.resolve` activates a source, `ox.service.attach` loads it, and page reload refreshes a document; none substitutes for another. Provider configuration needs no Browser, favicon, or service attachment. AI websites are services, never agent-loop provider transports.

For remote MCP, reuse saved definitions under `repositories/local/mcp/` or verify endpoint, transport, and authentication against supplied or official documentation. Create with `ox.service.create({ purpose, kind: "mcp", name, endpoint, transport? })`, omitting domain. Choose an explicit display name from the product name or user request; never derive it from the endpoint hostname or use the MCP server-reported name. Use the returned domain to attach, inspect, and verify tools. Creation saves without connecting or requesting login. Standard `connectionStatus` and `authorize` accept empty input and remain available before discovery succeeds. Do not author MCP API handlers or assume local stdio tools have HTTPS endpoints; report local-only limits and investigate documented API alternatives within scope.

## Service authoring loop

1. Diagnose before editing. Distinguish defects from login, human verification, rate limits, missing resources, and temporary failures. Failed discovery or catalog absence does not prove source is missing. For observed challenges, follow `references/web-handoffs.md`; do not bypass protection or misdiagnose it as a defect.
2. Inspect only the target and needed dependencies under `repositories/<repository-id>/<kind>/<domain>/`. Check `ox.repository.list` when identity/readiness is unknown and `ox.repository.conflicts` when source selection matters. Reuse suitable source. Copy eligible read-only source into Local without overwriting drafts; report uneditable source as blocked. Missing coverage means build, not unsupported domain. Local is always enabled; report readiness failures rather than deleting drafts or substituting domains. iOS services are not authorable.
3. Gather minimal live website or official API evidence. For new or updated customer-facing web/API services, verify `faviconUrl` through the icon reference before attachment; preserve drafts and existing attachments if verification fails.
4. Create or patch `service.json` and `actions.js`, preserving manifest schemas, intended behavior, and unrelated edits. Build capabilities any user of the product can reuse; the current request is a test case, not a constant. Register new `<kind>:<domain>` entries in `repositories/local/repository.json` without replacing existing entries. Use `ox.fs.edit` if an invalid manifest blocks `ox.service.update`. Do not delete actions to pass validation, replace intentional incomplete drafts, or silently switch to Built-in source. Reads normally use `requireApproval: false`; external mutations require approval.
5. Validate the complete affected Local draft with `ox.service.validate` using its bare domain. Repair confirmed failures, including obsolete authentication contracts, until valid or concretely blocked; do not repeat unchanged failures or treat validation errors as signed-out state. Explicitly resolve source conflicts, then attach/reload valid source. File operations neither select sources nor reload attachments.
6. Inspect needed contracts and invoke changed handlers on their actual execution pages under authentication and approval gates. Validation alone is not runtime verification. Check applicable pagination, authentication, concurrency, and handoffs. Never repeat completed mutations for testing; inspect uncertain effects read-only. Use `ox.service.listAttached` only when attachment remains uncertain.
7. Review final source/evidence, repair affected skills within scope, and complete the original request. Distinguish persisted drafts, validation, live verification, and blockers. Surface consequential source choices or unverifiable behavior rather than substituting excerpts for requested actions.

Audit unrelated drafts only when requested. For inventories, enumerate selected sources and invalid definitions with `ox.service.list`; use provenance rather than treating every merged VFS directory as Local. Catch each audit failure separately, retain diagnostics, and report inaccessible or truncated coverage. Do not attach unrelated services merely to audit them.

Batch predictable dependent steps, awaiting each and stopping on failure; parallelize only independent reads. Reuse unchanged contracts and source, refreshing for authentication, concurrent edits, or final review. Return compact evidence without trading verification for fewer turns.

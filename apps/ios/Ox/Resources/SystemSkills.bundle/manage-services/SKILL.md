---
name: manage-services
description: Manage Ox service definitions and remote MCP connections; build Local web and API services, including website requests with no suitable service. Not for ordinary use of existing services.
---

# Manage Services

Use existing services normally without this skill unless their definitions must change.

Read `skills/system:manage-services/references/web-service.md` for Local web-service authoring or substantive verification, including Browser fulfillment when successful discovery finds no suitable service for a website task. Inspection, copying, attachment changes, history, and straightforward deletion need no authoring reference.

Read `skills/system:manage-services/references/api-service.md` for direct HTTP API services with API-key, Basic, Bearer, or OAuth authentication.

## Ownership and safeguards

- Local API source at `services/api/<id>/` is editable and uses Host-managed authentication.
- Local web source at `services/web/<domain>/` is editable. Bundled source and Development/Remote manifests are read-only; copy eligible services with `ox.service.copy` before editing. iOS services are not authorable.
- Direct MCP connections use service tools, not editable manifests or Local Git. Repository-owned MCP definitions remain read-only.
- Discover with `ox.service.find` and `ox.service.listAttached`; inspect with `ox.service.inspect` and `ox.fs.read`.
- Do not change the manifest schema. Preserve runtime approval gates and unrelated Local changes. Inspect Local status and diff before Save, revert, restore, or deletion; keep abandoned work recoverable.
- Present Local persistence as **Save**, for example `Save Outlook service`. Keep Git and revision mechanics internal unless the user asks or recovery requires them.

## Remote MCP connections

Create with `ox.service.create({ kind: "mcp", endpoint, transport?, purpose })`. Use a credential-free public HTTPS endpoint; omit `domain` because Ox assigns it. Transport defaults to detection; explicit values are `streamable-http` and `sse`. Ox obtains approval, discovers tools, handles sign-in, and saves. Repeated creation reuses the endpoint.

Attach the returned `domain` before inspecting or invoking in chat. Update with `ox.service.update({ domain, endpoint?, transport?, purpose })`; omit settings to refresh tools or use `transport: "auto"` to restore detection. Updates require approval and validate before saving. A changed endpoint returns a new domain requiring attachment; never transfer credentials or tool approvals across endpoints.

Delete with `ox.service.delete({ domain, purpose })`. This removes the connection, local authorization, and tool approvals and detaches it from this chat, but does not revoke remote authorization or delete repository-owned definitions. MCP changes save immediately; connecting does not build or host a server.

---
name: manage-services
description: Manage Ox service definitions and remote MCP connections; build Local web and API services, including website requests with no suitable service. Not for ordinary use of existing services.
---

# Manage Services

Use existing services normally without this skill unless their definitions must change.

Read `skills/manage-services/references/web-service.md` for Local web-service authoring or substantive verification, including Browser fulfillment when successful discovery finds no suitable service for a website task. Inspection, copying, attachment changes, history, and straightforward deletion need no authoring reference.

For web-service authoring, read `skills/manage-services/references/helpers.js` only when a helper is needed. It is copyable source for `actions.js`, not an installed library, module, or runtime import.

Read `skills/manage-services/references/api-service.md` for direct HTTP API services with API-key, Basic, Bearer, or OAuth authentication.

Read `skills/manage-services/references/model-service.md` when adding or editing standard model-generation Actions on a web service. Model providers use the same copy-to-Local, conflict resolution, validation, and Save workflow as other services.

## Ownership and safeguards

- Local API source at `services/api/<id>/` is editable and uses Host-managed authentication.
- Local web source at `services/web/<domain>/` is editable. Bundled source and Development/Remote manifests are read-only; copy eligible services with `ox.service.copy` before editing. iOS services are not authorable.
- Direct MCP connections use service tools, not editable manifests or Local Git. Repository-owned MCP definitions remain read-only.
- Discover with `ox.service.find` and `ox.service.listAttached`; inspect with `ox.service.inspect` and `ox.fs.read`.
- Do not change the manifest schema. Preserve runtime approval gates and unrelated Local changes. Inspect Local status and diff before Save, revert, restore, or deletion; keep abandoned work recoverable.
- Present Local persistence as **Save**, for example `Save Outlook service`. Keep Git and revision mechanics internal unless the user asks or recovery requires them.

## Repositories

Use `ox.app.repositories({ purpose })` to list repository IDs and states. Connect a public HTTPS Git repository with `ox.repository.connect({ origin, purpose })`; it must contain `repository.json` at its root and the user approves the connection. Sync an installed Remote repository with `ox.repository.sync({ repository, purpose })`, using its ID from the list; syncing refreshes the existing connection and asks for user approval. Do not reconnect a repository to get newer services. Disconnect an installed Remote repository with `ox.repository.disconnect({ repository, purpose })`, using its ID from the list. Disconnect asks for user approval, removes its local snapshot and service definitions, and keeps website sign-ins and data. Bundled, Development, and Local repositories cannot be disconnected.

### Share Local services

Share only a saved, verified Local version. Run `ox.service.validate` for every selected service, inspect `ox.repository.git.status` and `ox.repository.git.diff`, then save the intended Local changes with `ox.repository.git.commit`. Use the returned full commit hash with `ox.repository.propose({ target: "openox", commitHash, services, title, body, status, purpose })`. `services` contains Local service domains, and `status` is explicitly `draft` or `open`.

The proposal action asks for approval, may ask the user to authorize the target provider, uploads the selected service files and target manifest through the provider API, and returns the change-request URL. It does not publish uncommitted work or clone the target repository. Never put credentials, session data, raw captures, or machine-specific files in a proposal.

## Remote MCP connections

Create with `ox.service.create({ kind: "mcp", endpoint, transport?, purpose })`. Use a credential-free public HTTPS endpoint; omit `domain` because Ox assigns it. Transport defaults to detection; explicit values are `streamable-http` and `sse`. Ox discovers tools, handles sign-in, and saves. Repeated creation reuses the endpoint.

Attach the returned `domain` before inspecting or invoking in chat. Update with `ox.service.update({ domain, endpoint?, transport?, purpose })`; omit settings to refresh tools or use `transport: "auto"` to restore detection. Updates validate before saving. A changed endpoint returns a new domain requiring attachment; never transfer credentials or tool approvals across endpoints.

Delete with `ox.service.delete({ domain, purpose })`. This removes the connection, local authorization, and tool approvals and detaches it from this chat, but does not revoke remote authorization or delete repository-owned definitions. MCP changes save immediately; connecting does not build or host a server.

Repositories can also share independent skills under root `skills/<name>/`. Read `skills/manage-skills/SKILL.md` when creating or publishing a reusable workflow. Services do not contain nested skills.

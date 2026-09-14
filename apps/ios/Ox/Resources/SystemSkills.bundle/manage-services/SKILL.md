---
name: manage-services
description: Create, inspect, copy, update, verify, version, or delete Ox service definitions, remote MCP connections, and Local web-service source. Do not use merely to invoke a service.
---

# Manage Services

Manage service definitions and source, not ordinary service use. For a user's task against an existing service, discover, attach, inspect, and invoke it without loading this skill unless its definition or implementation must change.

Respect repository ownership:

- Bundled services expose read-only source files. Development and Remote services expose read-only manifests. Inspect them directly or copy an eligible service into Local with `ox.service.copy` before editing.
- Local web services expose editable source under `services/web/<domain>/` and support create, read, update, delete, verification, and Git history.
- Remote MCP connections support creation, inspection, update, refresh, and deletion through service tools. Their manifests are read-only; they do not use the Local web-source or Git workflow. Repository-owned MCP definitions remain read-only.
- iOS services may be discovered and inspected but are not authorable through this workflow.

Use `ox.service.find`, `ox.service.listAttached`, `ox.service.inspect`, and `ox.fs.read` for discovery and inspection. Use `ox.service.create` for a new Local web service, `ox.service.copy` for an editable Local candidate, `ox.fs.write`, `ox.fs.edit`, and `ox.fs.delete` for source changes, `ox.service.validate` to check the whole draft, and `ox.service.delete` for a whole Local service. Inspect Local status and diff before saving, reverting, restoring, or deleting.

For creating, extending, repairing, or substantively verifying a Local web service, read `skills/system:manage-services/references/web-service.md`. For inspection, copying, attachment changes, history reads, or a straightforward user-requested deletion, proceed without loading the web authoring reference.

Do not modify the service manifest schema. Require the runtime's approval for gated mutations, preserve unrelated Local changes, and leave abandoned work recoverable through narrow Git operations.

Present Local persistence to the user as **Save**, never as Git, committing, a commit hash, or repository mechanics unless the user explicitly asks for technical details or recovery requires them. Internal Git tools remain the implementation of Save. Use short approval purposes such as `Save Outlook service`.

## Remote MCP connections

Create a connection with `ox.service.create({ kind: "mcp", endpoint, transport?, purpose })`. Use a public HTTPS endpoint with no credentials; omit `domain` because Ox assigns it. Transport defaults to automatic detection; explicit values are `streamable-http` and `sse`. The user approves the connection, and Ox discovers tools and handles sign-in before saving. Repeated creation reuses an existing endpoint.

Use the returned `domain` with inspect, attach, invoke, and delete. Attach before inspecting or invoking in chat. Update a directly connected server with `ox.service.update({ domain, endpoint?, transport?, purpose })`; omit settings to refresh its tools, or use `transport: "auto"` to restore detection. Updates require approval and validate the replacement before saving. A changed endpoint returns a new domain and must be attached separately. Never copy credentials or tool approvals to a different endpoint.

Delete with `ox.service.delete({ domain, purpose })`. This removes the saved connection, its local authorization, and tool approvals, and detaches it from this chat. It does not revoke authorization on the remote server or delete repository-owned definitions. MCP changes save immediately; do not run Local Git tools or write manifests for them. Creating a connection does not build or host an MCP server.

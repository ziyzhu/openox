---
name: manage-services
description: Create, inspect, copy, update, verify, version, or delete Ox service definitions and Local web-service source. Do not use merely to invoke a service.
---

# Manage Services

Manage service definitions and source, not ordinary service use. For a user's task against an existing service, discover, attach, inspect, and invoke it without loading this skill unless its definition or implementation must change.

Respect repository ownership:

- Bundled, Development, and Remote services expose read-only manifests. Inspect them directly or copy an eligible service into Local with `ox.service.copy` before editing.
- Local web services expose editable source under `services/web/<domain>/` and support create, read, update, delete, verification, and Git history.
- iOS and MCP services may be discovered and inspected but are not authorable through the Local web-service workflow.

Use `ox.service.find`, `ox.service.listAttached`, `ox.service.inspect`, and `ox.fs.read` for discovery and inspection. Use `ox.service.create` for a new Local web service, `ox.service.copy` for an editable Local candidate, `ox.fs.write`, `ox.fs.edit`, and `ox.fs.delete` for source changes, and `ox.service.delete` for a whole Local service. Inspect Local status and diff before committing, reverting, restoring, or deleting.

For creating, extending, repairing, or substantively verifying a Local web service, read `skills/system:manage-services/references/web-service.md`. For inspection, copying, attachment changes, history reads, or a straightforward user-requested deletion, proceed without loading the web authoring reference.

Do not modify the service manifest schema. Require the runtime's approval for gated mutations, preserve unrelated Local changes, and leave abandoned work recoverable through narrow Git operations.

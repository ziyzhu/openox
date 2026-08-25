# VM Contract

Status: Normative invariants with dynamically discovered function schemas.

The VM boundary consists of JSON values, isolated source execution, the runtime
`ox.*` function catalog, and a virtual filesystem. A compatible Host MAY use any
language engine, but MUST preserve the observable constraints in this directory.

The envelope used to inspect and invoke the VM is defined in `host/schema.ts`.
Individual function schemas are supplied by `vm-functions` at runtime because
availability depends on the Host, platform, Profile, session, and attached
services.

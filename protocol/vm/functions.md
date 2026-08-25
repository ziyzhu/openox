# VM Functions

Status: Normative discovery and invocation behavior.

`ox.*` functions MUST be discovered at runtime. Each advertised entry MUST have
a stable name, description, closed object input schema, and concrete output
schema. A Client MUST call only a name present in the catalog returned by the
same Host connection.

The Host MUST validate arguments before dispatch, apply authorization and
approval policy, and validate the returned value. Catalog availability may
depend on platform capability, Profile state, selected session, and attached
services.

`vm-functions` with no `function` returns an object whose `functions` member maps
complete function names to contracts. With `function`, it returns the exact
`name`, its `schema`, and human-readable `help`. Help text is informative; the
schema is authoritative.

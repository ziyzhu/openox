# VM Functions

`ox.*` functions are discovered at runtime. Each advertised entry has a stable
name, description, closed input schema, and concrete output schema. Calls are
valid only for names in the current catalog.

The Host validates arguments before dispatch, applies authorization and
approval policy, then validates the returned value. Catalog availability may
depend on platform capability, Profile state, selected session, and attached
services.

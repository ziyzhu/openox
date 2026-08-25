# VM Protocol

VM value rules, function discovery, validation, filesystem authority, and capability isolation are **Normative**. Function catalogs are dynamic and scoped to the current Host connection, profile, session, platform, and installed services.

## Execution

Code runs in an isolated VM with no ambient network, shell, device, or Host-filesystem access. All authority is exposed through `ox.*` functions. Execution is serialized within a VM. Cancellation must stop bridge work and produce a terminal operation result.

A Host may reuse an execution context, but must replace it when the owning profile changes. JavaScriptCore is an implementation choice, not a portable requirement.

## Values

Portable VM values are JSON values: `null`, booleans, finite numbers, strings, arrays, and objects with string keys. Function arguments are objects unless a function schema explicitly says otherwise. Binary data is represented through artifacts or a declared encoding.

`undefined`, functions, cyclic structures, non-finite numbers, and native handles are not portable values.

## Functions

Every discovered function has a stable name, description, closed object input schema, and concrete output schema. The catalog returned to a Client must describe the functions callable on that same connection.

The Host validates arguments before execution, enforces authentication and approval requirements, and validates the result before returning it. Availability may vary with platform, profile, session, and services.

Listing without a function name returns the complete function map. Looking up a named function returns that exact name, its schema, and help text. Help is informative; the schema is authoritative.

## Filesystem

The virtual filesystem can mount profile memory and soul files, artifacts, skills, service definitions, chats, and explicitly selected user files. Virtual paths must not expose Host paths or authority beyond the mounted source.

Profile skills may be writable. System and service skills are read-only. Local service source may be writable through its declared development capability. Context files and unrelated Host files are inaccessible unless explicitly mounted.

Reads must be bounded. Writes must be atomic and confined to writable mounts. The implementation reference for the complete namespace lives in `../../docs/VM.md`.

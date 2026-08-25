# Host Commands

Portable version 1 VM commands use a request envelope containing `kind`, `id`,
`protocolVersion`, and an optional `sessionId`.

- `vm-inspect` reports the Host, VM, selected session, and visible VFS roots.
- `vm-functions` reports the callable `ox.*` catalog or one function contract.
- `vm-call` invokes one advertised function with a JSON object.
- `vm-eval` evaluates JavaScript and is a development-only escape hatch.

The DEBUG simulator endpoint also accepts test, repository, composer, and UI
automation commands. Those commands are implementation diagnostics and are not
part of the portable Host protocol.

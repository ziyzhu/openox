# OpenOx Protocol

This directory owns the language-neutral contracts required for independent
OpenOx Clients, Hosts, Profiles, VMs, and service repositories to interoperate.
Platform implementations live under `apps/`; reusable implementation libraries
live under `packages/`.

The current normative surfaces are:

- `host/` for Client–Host lifecycle, commands, events, and transport mappings.
- `agent/` for observable turns, messages, tool calls, and stop reasons.
- `vm/` for JavaScript execution, `ox.*`, permissions, and virtual filesystem behavior.
- `profile/` for the portable Profile layout and persisted chat formats.
- `services/` for `repository.json`, `service.json`, actions, and repository compatibility.
- `security/` for approvals, credentials, isolation, and trust boundaries.
- `conformance/` for implementation-independent valid, invalid, and scenario fixtures.

Until machine-readable schemas are extracted here, the detailed VM, storage,
service repository, and security contracts remain in `docs/` and the canonical
validators remain in `packages/service-sdk/`.

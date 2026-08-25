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

Each surface contains focused contract documents rather than one monolithic
specification. Machine-readable service schemas and their conformance fixtures
live here; the canonical runtime validators remain in `packages/service-sdk/`.
Host, Agent, VM, Profile, and security documents describe the current contract
and explicitly identify surfaces that are not yet portable or remotely exposed.

`VERSION` is the major interoperability version. Compatible additions may be
made within a major version. Breaking changes require a new version directory
or an explicit migration before this value changes.

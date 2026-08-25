# OpenOx Protocol

This directory contains the implementation-independent contracts required for
OpenOx implementations to exchange service metadata, control a Host VM, and
read the portable metadata in an Ox Profile.

`VERSION` is the OpenOx protocol major version. Version 1 currently standardizes
only the surfaces marked Normative in `STATUS.md`. A document marked Draft is
design guidance and does not establish interoperability.

The words MUST, MUST NOT, REQUIRED, SHOULD, SHOULD NOT, and MAY are normative as
defined by RFC 2119 when they appear in a Normative document.

## Sources of truth

Executable TypeBox definitions in `schema.ts` and each surface's `schema.ts`
are the canonical structural schemas. The adjacent `*.schema.json` files are
generated language-neutral JSON Schema artifacts. Run:

```sh
bun run build:protocol
bun run check:protocol
```

Generated schemas MUST match their TypeScript sources. Conformance fixtures
MUST pass the tests under `conformance/`. Semantic requirements that JSON Schema
cannot express are stated in the surface documents and enforced by the
reference validators.

## Surfaces

- `services/` defines `repository.json`, `service.json`, actions, and repository compatibility.
- `host/` defines the version 1 VM control request and response envelopes.
- `profile/` defines `profile.json`, current `chat.json` metadata, and the portable directory layout.
- `vm/` defines execution, values, function discovery, and virtual filesystem invariants.
- `security/` defines authority, approval, credential, and isolation requirements.
- `agent/` records the draft provider-neutral Agent model; it is not yet a wire or storage schema.
- `conformance/` contains accepted and rejected examples tested against the canonical schemas.

Platform implementations live under `apps/`. Reusable implementation libraries
live under `packages/`. An implementation is conformant only to the specific
Normative surfaces it implements; directory presence alone does not imply full
OpenOx conformance.

# OpenOx Protocol

Code is the source of truth.

- `VERSION` is the protocol major version.
- `schema.ts` defines shared values.
- `host/schema.ts` defines development Host VM control.
- `profile/schema.ts` defines portable Profile and chat metadata.
- `services/schema.ts` defines service repositories and manifests.
- `conformance/` verifies schemas against implementations and fixtures.

Committed JSON Schemas are generated for non-TypeScript consumers. Run `bun run build:protocol` to regenerate them and `bun run check:protocol` to detect drift.

Behavior not encoded here belongs to the implementation and its tests until it has a machine-readable protocol contract.

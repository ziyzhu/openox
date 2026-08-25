# Service Repository Contract

Status: Normative for version 1.

`schema.ts` is the source of truth for the structural shapes of
`repository.json` and web `service.json`. The generated
`repository.schema.json` and `service.schema.json` are language-neutral
artifacts. The reference SDK MUST expose structurally identical TypeBox schemas;
conformance tests fail on drift.

Structural validity is necessary but not sufficient. `actions.md` and
`compatibility.md` state semantic constraints enforced by
`packages/service-sdk` that JSON Schema cannot completely express.

# Service Compatibility

Status: Normative for repository version 1.

Repository version 1 MUST use `repository.json`. Its `version` MUST equal `1`.
Each entry in `services` MUST be a qualified identity: `web:<domain>`,
`ios:<identifier>`, or `mcp:<identifier>`. It maps exactly to
`<kind>/<identity>/` beneath the repository root.

No two entries may have the same identity after removing the kind prefix. Thus
`web:aws` and `mcp:aws` conflict. A repository may list at most 256 services.
When `contentHash` is present it MUST be 64 lowercase hexadecimal characters
and MUST match the canonical exported content computed by the repository
compiler.

Authored service metadata MUST be named `service.json`. Readers MAY accept legacy
`ox.json` and `manifest.json` during migration, but writers and published
repositories MUST emit only the current names.

Hosts MUST reject unsupported repository versions, duplicate runtime identities,
unlisted service directories, invalid content hashes, and manifests that fail
the canonical SDK validators.

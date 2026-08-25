# Service Compatibility

Repository version 1 uses `repository.json` and qualified service identities:
`web:<domain>`, `ios:<identifier>`, or `mcp:<identifier>`. The listed identity
maps to `<kind>/<identity>/` and must match the service metadata.

Authored service metadata is named `service.json`. Readers may accept legacy
`ox.json` and `manifest.json` during migration, but writers and published
repositories emit only the current names.

Hosts reject unsupported repository versions, duplicate runtime identities,
unlisted service directories, invalid content hashes, and manifests that fail
the canonical SDK validators.

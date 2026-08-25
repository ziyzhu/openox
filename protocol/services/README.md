# Service Repository Contract

This surface owns `repository.json`, per-service `service.json`, action
contracts, service kinds, repository compatibility, and content validation.
The current detailed contract is in `docs/SERVICE_REPOSITORIES.md`; canonical
validators live in `packages/service-sdk/src/`.

- `repository.schema.json` defines the repository inventory shape.
- `service.schema.json` defines structural service and action metadata.
- `actions.md` defines action runtime and validation behavior.
- `compatibility.md` defines versions, identities, and legacy filenames.

# Protocol Status

| Surface | Status | Versioned contract |
| --- | --- | --- |
| Service repository inventory | Normative | `services/schema.ts#RepositoryPackageSchema` |
| Web service metadata | Normative | `services/schema.ts#ServiceManifestSchema` plus `services/actions.md` |
| VM control transport | Normative for development Hosts | `host/schema.ts` |
| Profile identity metadata | Normative | `profile/schema.ts#ProfileConfigSchema` |
| Chat metadata | Normative at schema version 1 | `profile/schema.ts#ChatMetadataSchema` |
| VM values and capability isolation | Normative | `vm/values.md`, `vm/execution.md`, `vm/functions.md` |
| Profile directory names and ownership | Normative | `profile/layout.md` |
| Security boundaries | Normative | `security/` |
| Remote Host lifecycle and event replay | Draft | `host/lifecycle.md`, `host/events.md` |
| Agent turns and messages | Draft | `agent/` |
| `turns.jsonl` and `context.json` schemas | Reference-implementation format | `docs/STORAGE.md` |

Normative for development Hosts means compatible implementations MAY expose the
version 1 VM control protocol, but OpenOx does not yet define the authentication,
discovery, reconnection, or event protocol required for a production remote Host.

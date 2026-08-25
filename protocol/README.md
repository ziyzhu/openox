# OpenOx Protocol

This directory defines OpenOx's implementation-independent contracts. It separates portable data and behavior from the current iOS, CLI, and service-runtime implementations.

Protocol requirements use **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** in their RFC 2119 sense. Only surfaces marked **Normative** are compatibility contracts.

`VERSION` contains the protocol major version. A breaking change to a normative contract requires a major-version change.

## Schemas

TypeBox definitions are the source of truth:

- `host/schema.ts`
- `profile/schema.ts`
- `services/schema.ts`

Their generated JSON Schemas are committed beside them for non-TypeScript consumers. Run `bun run build:protocol` to regenerate them and `bun run check:protocol` to verify generated output and conformance fixtures.

A conforming value MUST match its generated schema and any semantic requirements in the corresponding surface document. JSON Schema alone is not the complete contract.

## Surfaces and status

| Surface | Status | Contract |
| --- | --- | --- |
| Service repository inventory | Normative | `services/schema.ts#RepositoryPackageSchema` and `services/README.md` |
| Web service metadata | Normative | `services/schema.ts#ServicePackageSchema` and `services/README.md` |
| VM control | Normative for development Hosts | `host/schema.ts` and `host/README.md` |
| Profile identity metadata | Normative | `profile/schema.ts#ProfileConfigSchema` and `profile/README.md` |
| Chat metadata | Normative for schema version 1 | `profile/schema.ts#ChatMetadataSchema` and `profile/README.md` |
| VM values and capability isolation | Normative | `vm/README.md` |
| Profile directory ownership | Normative | `profile/README.md` |
| Security boundaries | Normative | `security/README.md` |
| Remote Host lifecycle and events | Draft | `host/README.md` |
| Agent turns and messages | Draft | `agent/README.md` |
| `turns.jsonl` and `context.json` encoding | Reference implementation | `docs/STORAGE.md` |

The development Host protocol does not define production remote authentication, discovery, reconnection, or event delivery.

## Ownership

Applications and packages implement these contracts; they do not redefine them. Conformance fixtures cover only the normative schemas and semantics represented in `conformance/`. Implementation-specific storage, UI projection, provider adapters, and deployment behavior remain outside the portable protocol.

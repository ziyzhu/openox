# OpenOx protocols

`@openox/protocol` owns platform-neutral contracts for the Client–Host JSON-RPC
interface and Host–Repository content interface. It is independent of iOS and
LLM providers. RPC and repository contracts have separate versions.

```sh
bun add @openox/protocol
```

## Client–Host contract

- `src/contract.ts` defines RPC schemas, method mappings, and the contract version.
- `schema.json` is portable JSON Schema Draft 7, with local `definitions` references.
- `methods.json` maps methods to parameter/result schema references.
- `fixtures.json` supplies language-neutral conformance examples.
- `src/index.ts` exports TypeScript validation helpers.

Hosts advertise supported methods in `host.describe.methods` and RPC versions
in `host.describe.protocols.rpc`. Clients can use older Hosts without that
version field. Contract versions are independent of app marketing versions.

```ts
import { isMethod, validateParams, validateResult } from "@openox/protocol";

const supported = isMethod(request.method);
const valid = supported && validateParams(request.method, request.params);
```

Hosts must validate the JSON-RPC envelope, select supported methods, check
parameters, and enforce authorization and runtime policies before dispatch.
Use `validateResult` to check handler outputs. Unknown method names pass through
the generic validators so extensions remain possible; validation alone does not
establish that a method is supported.

Other languages can load `schema.json` into a Draft 7 validator and resolve the
references from `methods.json` locally. Normalize omitted parameters and
compatibility `[]` to `{}`; explicit `null` is not normalized.

## Validation boundaries

- Most parameter objects allow unknown fields. No-parameter methods require an
  empty object after normalization.
- Optional request fields accept omission and explicit null. Optional typed
  result fields may be absent without accepting null; declared JSON values can
  contain null.
- Strings are not implicitly UUID/date-validated. Base64 `contentEncoding` is an
  annotation; Hosts must enforce decoding and byte limits.
- ProviderModel, Message, Block, and migration Turn payloads are opaque objects.
  Their codecs own nested formats; these schemas do not redefine storage.
- Chat existence, active UI availability, approvals, VM argument shape, resource
  limits, and ingress restrictions remain Host runtime checks.

Notifications omit `id` and receive no response. Batches contain 1–64 requests.
Request IDs correlate responses; they are not deduplication keys. Clients must
not retry a mutation merely because its result is invalid or the connection
failed after submission. The operation may already have executed.

## Log pagination

`logs.list` supports a bounded page size, cursor, and filters. Filters run before
the page limit. The first page contains the newest matches; each page is
chronological, and `nextCursor` retrieves older matches when `hasMore` is true.

Keep filters unchanged across pages. Cursors survive appends and app restarts,
but compaction or file changes can expire them; start a fresh read on expiration.
Results without `hasMore` indicate an older Host without pagination support.
Log sequence values are snapshot positions, not durable event IDs. Log follow
and chat watch use bounded snapshot polling.

## Host–Repository contract

| Export | Responsibility |
| --- | --- |
| `@openox/protocol/repository` | Repository index, supported versions, service identities and paths |
| `@openox/protocol/manifest` | Web/API manifests, action schemas, semantic validation |
| `@openox/protocol/catalog` | Native iOS and MCP catalog manifests |
| `@openox/protocol/installer` | Installer registration contract and inspection |
| `@openox/protocol/action` | Action installer TypeScript interfaces |
| `@openox/protocol/model-actions` | Standard model Action schemas and validation |
| `@openox/protocol/skills` | Reserved names, package limits, frontmatter and resource-path rules |

`repository.schema.json` validates `repository.json` and exposes service, auth,
and catalog shapes under `definitions`. Semantic validators are also required:
JSON Schema alone does not check duplicate identities, reserved names, URL
relationships, standard Actions, or installer registration.

The [services package](../services/README.md) supplies filesystem skill readers
through `@openox/services/skills`. Protocol modules do not depend on services or
Node filesystem APIs.

## Development

After changing the authoritative source, regenerate artifacts and verify them:

```sh
bun run build:host-schema
bun run build:repository-schema
bun run typecheck
bun test ./.agents/skills/test/contracts/client-host
```

CI checks generated JSON and Swift artifacts against the source. Do not edit
generated files. iOS uses generated RPC request models and supported repository
versions, with platform codecs for runtime validation. Storage migration and
legacy handling remain exclusively behind `StorageMigrator`.

Portable CLI process E2E checks use a controlled WebSocket fixture. They do not
establish live iOS Host conformance, Tailscale authorization, or lifecycle
correctness. See the [test skill](../../.agents/skills/test/SKILL.md) for
verification and the [release skill](../../.agents/skills/release/SKILL.md) for
publication.

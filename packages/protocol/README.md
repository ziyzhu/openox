# Host RPC contract

Platform-neutral contract for OpenOx's JSON-RPC 2.0 Client–Host interface.
It is independent of iOS, the service manifest, and any LLM provider.

## Files and ownership

- `src/contract.ts` — authoritative TypeBox/JSON Schema definitions, 35 method mappings, and RPC contract version.
- `schema.json` — generated, portable JSON Schema Draft 7 document. All references are local under `definitions`.
- `methods.json` — generated method catalog mapping names to parameter/result schema references. This is a small catalog, not an OpenRPC document.
- `fixtures.json` — language-neutral valid/invalid conformance examples.
- `src/index.ts` — reusable TypeScript validation. Clients and TypeScript Hosts consume the same schemas.
- `apps/ios/Ox/Host/RPC/HostRPCRequests.swift` — generated iOS method enum and request models. Swift continues to use [Decodable](https://developer.apple.com/documentation/swift/decodable) and JSONDecoder, not a second handwritten schema validator.

After changing the source:

```sh
bun run build:host-schema
bun run check:host-schema
bun run typecheck
bun test tooling/tests/host-rpc-contract.test.ts tooling/tests/host-rpc.test.ts
```

CI checks that generated JSON and Swift artifacts match the source. Do not edit generated files.

## Host integration

A Host may advertise the methods it implements in `host.describe.methods` and
advertise supported contract versions in `host.describe.protocols.rpc`, currently
`[1]`. This is independent of the app marketing version and repository protocol.
Older Hosts without the new version field remain usable by the CLI.

For a TypeScript Host:

```ts
import { isMethod, validateParams, validateResult } from "@openox/protocol";

// After validating the JSON-RPC envelope:
if (!isMethod(request.method)) {
  // Return -32601, or dispatch a separately defined extension method.
} else if (!validateParams(request.method, request.params)) {
  // Return -32602. Do not invoke the handler.
} else {
  // Check authorization, Profile/chat scope, and runtime policies, then invoke.
  // validateResult(method, result) can check output in tests/development.
}
```

A Host in another language can load `schema.json` into a Draft 7 validator and
use the `params`/`result` references in `methods.json`. Resolve references against
the schema document, not by fetching the schema's identifying URN. Normalize
omitted parameters and compatibility `[]` to `{}` before method validation.
Explicit `null` parameters are not normalized.

The generic request schema accepts method names beyond this catalog. The
TypeScript method validators deliberately pass through unknown method names;
Hosts must separately select supported methods, and Clients can call extensions.

## Compatibility and validation boundaries

Version 1 records the existing wire shapes; it does not tighten business rules:

- Most parameter objects accept unknown fields, as Swift Codable already does.
  No-parameter methods require an empty object (or omitted parameters/`[]`).
- Optional request fields accept omission and explicit null. Optional typed
  result fields are omitted by Swift Encodable when absent; they do not imply
  nullable values. Explicit JSONValue nulls remain valid where declared.
- Strings are not UUID/date-validated merely because existing implementations
  commonly put UUIDs or dates in them.
- Base64 `contentEncoding` is an annotation. Hosts must still decode binary
  data and enforce byte limits using their existing codecs.
- ProviderModel, Message, Block, and migration Turn payloads are deliberately
  opaque objects in this first contract. Their nested domain formats remain
  owned by their existing codecs; the shared schema does not claim to validate
  their complete contents or redefine persisted storage.
- Chat existence, active UI availability, action approval, eval bounds, VM
  function lookup, authorization, resource limits, and ingress restrictions
  remain runtime checks. For example, `vm.call.arguments` accepts JSON at the
  decode boundary; the handler separately requires an object.

Notifications omit `id` and receive no response. IDs correlate requests; they
are not durable operation identifiers or deduplication keys. Batches contain
1–64 requests. Streams such as chat watch and log follow still poll snapshots.

The CLI validates known method parameters before submission and validates
successful results. An invalid result after submission does not authorize a
retry: the operation may have executed, and no request is automatically resent.

## Conformance

The retained E2E suite validates the shared contract against a live Host.
`fixtures.json` is also available to Host implementations in other languages.

Run the live, read-only/invalid-parameter suite against any available Host:

```sh
OX_RPC_TEST_ENDPOINT=ws://<host>:9876 bun test tooling/tests/host-rpc-contract.test.ts
```

The live suite validates advertised read operations and sends only structurally
invalid mutation requests, which must fail decoding before their handlers run.
For iOS, enable Host connections, connect Tailscale, and keep Ox foregrounded.
This suite does not establish tailnet authorization or lifecycle correctness.

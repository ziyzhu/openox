# Ox Host contracts

Ox has two compatibility boundaries: Client ↔ Host and Host ↔ service
repositories, services, and skills. Software releases identify implementations;
contracts describe what those implementations understand. Profile storage
milestones remain an internal Host migration responsibility.

## Client ↔ Host

The simulator's loopback WebSocket endpoint uses JSON-RPC 2.0 exclusively.
Clients and Hosts must be updated together. Old `kind` requests and
`ok`/`error` response envelopes are rejected; there is no compatibility adapter.
The listener remains simulator-only and loopback-only. This change does not
introduce remote deployment or authentication.

Requests use `jsonrpc`, `id`, `method`, and optional `params`. Responses contain
exactly one of `result` or `error`. IDs accept strings, numbers, or null; the CLI
uses string UUIDs. Parameters are named objects; omitted parameters and `[]`
mean an empty object. Required fields are decoded before an operation runs.

```json
{"jsonrpc":"2.0","id":"1","method":"chats.get","params":{"sessionId":"…"}}
```

Payloads contain only method data. Request IDs and outcome/error metadata belong
to the RPC envelope. Application failures use code `-32000`; any partial result,
agent timings, or VM logs are preserved in `error.data`. Standard codes cover
parse errors (`-32700`), invalid requests (`-32600`), unknown methods (`-32601`),
invalid parameters (`-32602`), and internal errors (`-32603`).

Notifications omit `id` and receive no response, including on failure. Batches
return responses only for non-notification entries; an all-notification batch
produces no message. The Host currently processes entries within a batch
sequentially. Separate WebSocket messages can have concurrent operations.

### Discovery and versions

Each compatibility boundary has its own version line. The Host advertises the
set of versions it supports; each consumer declares the single version it
targets. Boundaries advance independently because their support windows differ:
lockstep clients can drop old RPC versions immediately, while persisted services
may need old versions for much longer.

`HostProtocols` is the single Host-side list of supported versions:

| Line | Consumer declares | Host supports | Checked |
| --- | --- | --- | --- |
| `rpc` | `RPC_VERSION` in `HostRPCClient` | 1 | once per connection, by the client |
| `repository` | `version` in `repository.json` | 1 | when a repository loads |
| `action` | `window.ox.install(<version>, …)` in `actions.js` | 1, 2 | when a service is validated |
| `skill` | nothing yet; undeclared means 1 | 1 | not checked |

`host.describe` returns `implementation` (`name`, `version`, `build`),
`protocols`, the lists above, and `methods`, the method names derived from the
same `OxHostProtocol.Method` enum used for dispatch. These versions are
independent of the JSON-RPC envelope version and software release versions.
Unsupported versions fail with both the declared and supported versions named.

The shared TypeScript `HostRPCClient` declares `RPC_VERSION` and checks it
against `protocols.rpc` once per connection, before its first operation. An
incompatible Host fails before any operation is sent. Unknown methods fail with
`-32601`. Additive response fields and new methods do not change the version.
Changes to required fields, field types, or established behavior of any method
require a new RPC version. The Host may support several RPC versions while
clients migrate.

| Area | Methods |
| --- | --- |
| Host | `host.describe` |
| Chats | `chats.list`, `chats.get` |
| Models and agents | `models.list`, `agents.run` |
| Logs | `logs.list` |
| VM | `vm.inspect`, `vm.functions`, `vm.call`, `vm.eval` |
| Services | `services.list`, `services.invoke`, `services.evaluate`, `services.reload`, `services.refreshAuth`, `services.sync` |
| Test setup | `debug.providers.setKey`, `debug.region.set`, `debug.chats.attachServices` |
| Fixtures | `debug.artifacts.bootstrap`, `debug.artifacts.write`, `debug.websiteData.export`, `debug.websiteData.restore`, `debug.repositories.saveGate`, `debug.storage.replayMigration` |
| UI automation | `debug.composer.formatting`, `debug.composer.setDraft`, `debug.composer.setMarkedText`, `debug.chat.setEditDraft`, `debug.pasteboard.setImage`, `debug.pasteboard.setRichText`, `debug.share.stageNote` |

The redundant older VM evaluator has been removed; `vm.eval` is the single
snippet execution method. VM method compatibility is covered by the RPC version
rather than a second `protocolVersion` field on each request and response.

`OxHost.listChats()` returns typed snapshots shared with the local `OxClient`.
Other Host operations still use their existing managers internally. RPC changes
serialization and dispatch without routing in-process UI calls through JSON.

### Client behavior

One `HostConnection` implementation owns WebSocket lifecycle, request IDs,
response validation, timeouts, and pending calls. `HostRPCClient` adds the RPC
version check and typed chat/discovery validation. CLI commands and test harnesses use
these helpers. Errors are exceptions carrying an RPC code and optional data;
there is no second success/failure envelope inside method results.

Malformed replies fail explicitly. A timeout does not cancel Host work, and
requests are not automatically retried. Chat/log watch commands may reconnect
and retry their read-only queries. Agent runs retain their existing single final
response; streaming, cancellation, and event replay are separate future changes.

```sh
ox --host ws://127.0.0.1:9103 host describe --json
ox --host ws://127.0.0.1:9103 chat list --json
ox --host ws://127.0.0.1:9103 vm inspect --json
bun run test:host-rpc
OX_RPC_TEST_ENDPOINT=ws://127.0.0.1:9103 bun run test:host-rpc
```

CI runs client tests against local WebSocket fixtures. The optional live suite
exercises the Swift adapter, discovery, domain methods, errors, notifications,
batches, and rejection of the removed protocol. The standalone CLI check also
uses JSON-RPC.

## Host ↔ repositories, services, and skills

Repository and action versions are declared by the content and gated through
`HostProtocols` as described above. Adding an action ABI also requires the
service runtimes (`ServiceActionRuntime.js`, `APIService`, and the
`@openox/services` inspector) to implement it. Repository content hashes and Git commits identify exact
contents independently of format compatibility. These content interfaces are
not converted into RPC by this change.

Skills contain instructions whose tool assumptions can change even when their
Markdown remains readable. Skills do not declare a version yet; the Host treats
every skill as version 1. Introduce a declared skill version together with the
first incompatible skill change. No repository, skill, or service manifest
schema changes are introduced.

## References

- [JSON-RPC 2.0 specification](https://www.jsonrpc.org/specification)
- [Apple Encodable documentation](https://developer.apple.com/documentation/swift/encodable)

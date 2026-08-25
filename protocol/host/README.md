# Host Protocol

The development Host VM-control protocol is **Normative for version 1**. Remote lifecycle and event delivery are **Draft**.

The Host owns profiles, chats, model adapters, services, and VM execution. A Client uses Host operations and must not assume ownership of those resources. The iOS app uses the Host directly in-process. The WebSocket transport is a loopback DEBUG interface, not a production remote-host protocol.

## Operations

A version 1 development Host exposes exactly four protocol operations:

| Operation | Additional request fields | Session | Result kind |
| --- | --- | --- | --- |
| `vm-inspect` | None | Optional; otherwise the Host's active chat | `vm-inspect-result` |
| `vm-functions` | Optional nonempty `function` | None | `vm-functions-result` |
| `vm-call` | Nonempty `function`, object `arguments` | Explicit or the Host's active chat | `vm-call-result` |
| `vm-eval` | Nonempty `script` | Explicit or the Host's active chat | `vm-eval-result` |

Every request MUST be one JSON object matching `vm-control-request.schema.json`. Its `id` is a nonempty caller-generated correlation identifier and `protocolVersion` MUST be `1`. When present, `sessionId` MUST be nonempty.

`vm-functions` without a function name returns `{ functions: { ... } }`. With a name, it returns `{ name, schema, help }` or an unknown-function failure. `vm-call` MUST reject arrays, primitives, `null`, unknown functions, invalid inputs, and invalid outputs. `vm-eval` is a development escape hatch and does not expand VM authority. A production Host MUST NOT expose it unless Host policy explicitly permits arbitrary VM source execution.

Other iOS DEBUG simulator commands are test automation. A conforming Host MUST NOT advertise them as protocol operations.

## Responses and errors

Every response MUST match `vm-control-response.schema.json`, repeat the request `id`, use `protocolVersion: 1`, and carry the result kind corresponding to the request operation.

A successful response has `ok: true`, MAY contain a JSON `value` and ordered `{ level, message }` logs, and MUST NOT contain `error`. A failed response has `ok: false`, MUST contain a nonempty diagnostic `error`, MAY contain logs produced before failure, and MUST NOT contain `value`. Clients MUST NOT branch on error-message text. Transport failures occur outside the response envelope.

## In-process transport

An in-process Client invokes the same typed operations directly. It does not serialize requests, open a socket, or create a second runtime. It must preserve the same profile ownership, authorization, approval, session selection, validation, and value rules as any other transport.

Inputs and outputs must remain representable by the protocol schemas even when no JSON serialization occurs.

## WebSocket transport

The loopback DEBUG transport sends one UTF-8 JSON request per text frame and returns one response correlated by `id`. Multiple requests may be outstanding and responses may arrive in any order.

Malformed input without a usable `id` cannot receive a correlated protocol response. Closing the connection fails all outstanding requests. Version 1 defines neither idempotency nor automatic retry; a Client must not automatically retry an operation that may have produced an effect.

## Lifecycle and events

Version 1 does not define remote authentication, Host discovery, capability negotiation, session resumption, background delivery, or multi-client coordination. It also defines no general event envelope. Typed state embedded in operation results is normative, while the WebSocket interface remains request-response only.

A future event protocol will need stable event identities, ordering, replay boundaries, snapshots, terminal semantics, duplicate handling, and reconnect behavior before it can become normative.

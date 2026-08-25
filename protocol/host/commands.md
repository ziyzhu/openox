# VM Control Commands

Status: Normative for protocol version 1 development Hosts.

Every request MUST be one JSON object matching
`vm-control-request.schema.json`. `id` is a nonempty caller-generated correlation
identifier. `protocolVersion` MUST equal `1`. `sessionId`, when present, is a
nonempty Host chat identifier.

| Kind | Additional fields | Session requirement | Result kind |
| --- | --- | --- | --- |
| `vm-inspect` | none | Optional; omitted selects the active chat when available | `vm-inspect-result` |
| `vm-functions` | optional nonempty `function` | None | `vm-functions-result` |
| `vm-call` | nonempty `function`, object `arguments` | Required explicitly or through Host active-chat selection | `vm-call-result` |
| `vm-eval` | nonempty `script` | Required explicitly or through Host active-chat selection | `vm-eval-result` |

`vm-functions` without `function` returns `{ "functions": { ... } }`. With a
function name it returns `{ "name", "schema", "help" }` or a failure for an
unknown name.

`vm-call` MUST reject arrays, primitives, and null as `arguments`. It MUST reject
names absent from the current `vm-functions` catalog. The Host MUST validate the
function's own input and output contracts in addition to the envelope.

`vm-eval` is a development escape hatch. A production Host MUST NOT expose it
unless its security policy explicitly permits arbitrary VM source execution.

# VM Control Responses and Errors

Status: Normative for protocol version 1 development Hosts.

Every response MUST match `vm-control-response.schema.json`, repeat the request
`id`, use the corresponding result `kind`, and contain `protocolVersion: 1`.

A successful response has `ok: true`, MAY contain a JSON `value`, MAY contain
ordered `{ level, message }` logs, and MUST NOT contain `error`.

A failed response has `ok: false`, MUST contain a nonempty `error`, MAY contain
logs produced before failure, and MUST NOT contain `value`.

Version 1 error text is diagnostic and not machine-readable. Clients MUST NOT
branch on its wording. Transport failures occur outside this response envelope.

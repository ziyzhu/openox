# WebSocket Mapping

Status: Normative for version 1 development Hosts.

The Client MUST send one UTF-8 JSON request object in one WebSocket text frame.
The Host MUST return one UTF-8 JSON response object correlated by `id`. Requests
may be concurrent on one connection; responses may arrive in any order.

Malformed JSON and envelopes without a usable `id` cannot produce a correlated
protocol response. Connection close fails all outstanding requests. Version 1
defines neither retries nor idempotency; a Client MUST NOT automatically retry
an operation that may have produced an effect.

The reference endpoint uses loopback and is not a production remote transport.

# WebSocket Transport

The reference WebSocket transport sends one JSON request per text frame and
returns JSON responses correlated by `id`. Versioned VM operations include
`protocolVersion: 1`.

The current iOS listener is available only to DEBUG simulator builds and binds
to loopback. It is a development transport, not a remotely authenticated Host
endpoint. Production remote use requires authentication, capability
negotiation, event delivery, reconnection, and replay semantics.

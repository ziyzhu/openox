# Host Contract

This surface will define Client–Host lifecycle, capability negotiation, chat
commands, streaming events, approvals, service attachment, transport mappings,
and stable errors. The iOS implementation currently lives in
`apps/ios/OpenOx/Host/`.

- `lifecycle.md` defines Host selection, connection, and session binding.
- `commands.md` separates portable VM operations from development controls.
- `events.md` defines ordering and delivery requirements for observable events.
- `errors.md` defines error behavior across transports.
- `transports/` maps the same Host contract to embedded and WebSocket clients.

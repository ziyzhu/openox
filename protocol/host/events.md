# Host Events

Status: Draft. Version 1 defines no portable Host event envelope.

The embedded iOS Client observes typed in-process state. The DEBUG WebSocket
control protocol is request-response only. Compatible implementations MUST NOT
claim resumable streaming, replay, or remote Client synchronization based on
these implementation-specific mechanisms.

A future event protocol must define stable event identifiers, ordering per
session, replay cursors, snapshot boundaries, terminal-event ordering,
duplicate delivery, and behavior after reconnect.

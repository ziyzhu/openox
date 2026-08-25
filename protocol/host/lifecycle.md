# Host Lifecycle

Status: Draft except for ownership rules stated below.

The Host owns Profiles, chats, model adapters, services, and VM instances. A
Client MUST use Host operations rather than opening those resources concurrently
behind the Host.

The iOS Client uses direct in-process dispatch. The current WebSocket listener
is a loopback-only DEBUG simulator endpoint. Version 1 does not define remote
authentication, discovery, capability negotiation, connection resumption,
background execution delivery, or multi-Client conflict handling.

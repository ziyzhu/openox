# OpenOx Protocol

OpenOx is a set of components joined by explicit contracts. A contract belongs at a boundary; it does not require a separate schema when both sides already share language types in one process.

Code is the source of truth. This document maps each boundary to the code that defines it and states which parts are portable today.

## Components

```text
Client ↔ Host
          ├── Agent ↔ Model Provider
          │     ↕
          │     VM ↔ Host capabilities
          ├── Profile
          └── Service Repository → Services
```

- A **Client** presents and controls an Ox.
- A **Host** owns chats, services, Profiles, model adapters, and VM execution.
- An **Agent** reasons and uses tools to pursue a goal.
- A **Model Provider** supplies inference behind a provider-neutral adapter.
- A **Profile** is the portable folder containing persistent Ox state.
- A **VM** executes agent code with only explicit Host capabilities.
- A **Service Repository** supplies versioned services, typed actions, and skills.

Components communicate only through adjacent boundaries. A Client does not reach directly into an Agent, Profile, VM, or service; the Host mediates those relationships.

## Contract ownership

| Boundary | Source of truth | Status |
| --- | --- | --- |
| Native Client ↔ Host | [`OxHost.swift`](../apps/ios/Ox/Host/OxHost.swift) | In-process Swift contract |
| Development CLI ↔ Host | [`vm-protocol.ts`](../apps/cli/src/vm-protocol.ts), [`OxHostProtocolMessages.swift`](../apps/ios/Ox/Host/OxHostProtocolMessages.swift) | Version 1 VM control; DEBUG Simulator only |
| WebSocket transport | [`debug-ws.ts`](../apps/cli/src/debug-ws.ts), [`WebSocketOxHostTransport.swift`](../apps/ios/Ox/Host/WebSocketOxHostTransport.swift) | Loopback development transport |
| Host ↔ Agent | [`Agent.swift`](../apps/ios/Ox/Host/Agent/Agent.swift), [`AgentRunner.swift`](../apps/ios/Ox/Host/Agent/AgentRunner.swift) | In-process Swift contract |
| Agent ↔ Model Provider | [`LLMClient.swift`](../apps/ios/Ox/Host/Agent/LLM/LLMClient.swift) | Provider-neutral Swift contract |
| Agent ↔ VM | [`ChatJavaScriptTool.swift`](../apps/ios/Ox/Host/Chats/ChatJavaScriptTool.swift), [`VirtualMachine.swift`](../apps/ios/Ox/Host/VM/VirtualMachine.swift) | In-process Swift contract |
| VM ↔ Host capabilities | [`OxFunction.swift`](../apps/ios/Ox/Host/VM/OxFunctions/OxFunction.swift), [`OxFunctionBridge.swift`](../apps/ios/Ox/Host/VM/OxFunctions/OxFunctionBridge.swift) | Runtime-discovered `ox.*` contract |
| Host ↔ Profile | [`Profile.swift`](../apps/ios/Ox/Host/Profile/Profile.swift), [`ChatModel.swift`](../apps/ios/Ox/Host/Chats/ChatModel.swift), [`StorageMigration.swift`](../apps/ios/Ox/Host/Profile/StorageMigration.swift), [`ProfileMigration.swift`](../apps/ios/Ox/Host/Profile/ProfileMigration.swift) | Versioned persisted format |
| Host ↔ Service Repository | [`repository.ts`](../packages/service-sdk/src/repository.ts), [`ServiceRepository.swift`](../apps/ios/Ox/Host/Services/Repository/ServiceRepository.swift) | Repository version 1 |
| Host ↔ Service action | [`manifest.ts`](../packages/service-sdk/src/manifest.ts), [`ServiceManifest.swift`](../apps/ios/Ox/Host/Services/ServiceManifest.swift) | Validated service contract |

Detailed VM behavior is documented in [`VM.md`](VM.md). Persisted-storage ownership remains in the Profile implementation linked above.

## When a schema is required

A boundary needs a machine-readable schema when its data is:

- serialized across a process or network;
- persisted in a portable format;
- accepted from an untrusted repository or service; or
- consumed by an independent implementation.

TypeScript TypeBox schemas currently validate development Host VM messages and service metadata. Swift types and protocols define in-process iOS boundaries. A second schema must not duplicate an in-process contract merely for documentation; independent representations require generation or a parity check.

## Messages and transport

Messages define operations, payloads, results, errors, identifiers, and versions. A transport only carries those messages.

The native iOS Client calls its Host directly through `OxHost`. The development CLI sends VM-control messages over WebSocket. These transports have different encodings and lifecycle behavior, but they target the same Host-owned state.

The current WebSocket endpoint is a loopback DEBUG Simulator interface. It does not define production authentication, discovery, capability negotiation, events, reconnection, resumption, or multi-client coordination. Other simulator automation commands are implementation tooling rather than portable OpenOx operations.

## Versioning

OpenOx does not use one global version for unrelated boundaries. Each serialized surface advances independently:

- VM control uses `VM_PROTOCOL_VERSION`.
- Service repositories use `REPOSITORY_VERSION`.
- Chat metadata uses `ChatFormat.currentSchemaVersion`.
- Profiles use the ordered milestones in `ProfileSchema`.

A breaking change requires a new version or an explicit migration at that boundary. In-process refactors that preserve observable behavior do not require a wire-format version.

## Adding a contract

Before adding a schema, identify both components, the data crossing between them, who validates it, and whether another implementation consumes it. Keep the contract beside a real consumer. Extract a shared package only when multiple implementations need the same machine-readable definition.

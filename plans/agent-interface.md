# Agent interface

Status: proposed; no runtime changes. Separate Ox into Client, Host and Agent, so a Host conversation can run on Ox's built-in agent or on any agent elsewhere (pi, Claude Code, Codex) through one interface. Host↔Agent mirrors Client↔Host: a local in-process connection or a remote WebSocket JSON-RPC endpoint.

## Problem

`Conversation` reaches pi-durable through `DurableConversation.swift` and one JavaScriptCore entry point that takes about 50 actions in `packages/agent/src/adapters/ios/agent.ts`. Those actions mix three concerns:

| Concern | Actions | Destination |
|---|---|---|
| Agent | `attach`, `run`, `continue`, `abort`, `resume`, `resumeExisting`, `conversationContext`, `composePrompt` | the agent interface |
| Host storage | `application*`, `conversationList/History/Present/Read/Record`, schedules, profile, `file*` | stays Host-internal for every conversation |
| Ox tool backends | `filesystem*`, `fileMounts`, `skillPackages`, `nativeModel`, `nativeTool` | stays inside the local agent |

Only the first row belongs to an agent. Because all three share one channel, no other agent can be plugged in.

## Goal

- One `AgentConnection` used by `Conversation` for every agent, built-in or not.
- Two connection kinds only: `.local` (built-in pi-durable in-process) and `.remote(endpoint)` (WebSocket JSON-RPC 2.0 to `ox agent serve`).
- Agent-specific translation lives in `ox agent serve`, never in the Host.
- With only the built-in agent configured, behavior and UI are unchanged.

Non-goals for v1: Ox tools (services, VM, canvas, skills) inside external agents, which can later be offered as an MCP server passed at launch; Ox-side compaction or prompt composition for external agents; switching agent within a conversation.

## Mirror of Client↔Host

| Client↔Host | Host↔Agent |
|---|---|
| `HostSelection .local / .remote(endpoint:)` | `AgentSelection .local / .remote(endpoint:)`, per conversation |
| `HostConfiguration.remoteHosts` | `AgentConfiguration.remoteAgents [{name, endpoint}]`, stored on the Host |
| in-process `OxHost` | in-process built-in agent |
| WebSocket JSON-RPC 2.0, port 9876 | WebSocket JSON-RPC 2.0 to `ox agent serve`, port 9877 |
| `host.describe` | `agent.describe` |
| `RemoteHostProbe` statuses | same statuses for agent rows |
| `HostProtocols.unsupported` | same for the `agent` protocol version |
| `OX_HOST_ENDPOINT`, `ox host list` | `OX_AGENT_ENDPOINT`, `ox agent list` |
| Tailscale, trusted network only | same |

An agent on the same Mac is remote at `ws://127.0.0.1:9877`. The macOS Host is sandboxed (`apps/macos/host.entitlements`), so only `ox agent serve` spawns processes.

## Protocol

Envelope is JSON-RPC 2.0 like Client↔Host. Payloads are pi's RPC events and pi-ai messages, which `DurableMessageCodec` already decodes. Methods are generated from `packages/protocol/agent-methods.json`.

```text
agent.describe          → implementation {name, version}, machine, folder, protocols {agent: [1]}, methods
session.prompt          {text, images?} → {disposition}
session.abort
session.messages        → pi-ai messages
session.state           → model, thinkingLevel, isStreaming, sessionId
models.list             → models
session.setModel        {provider, id}
session.setThinking     {level}
session.respond         {promptId, answer}
notify session.event    agent_start, agent_settled, turn_*, message_*, tool_execution_*, compaction_*
notify session.prompt   {id, method: confirm|select|input, title, options?, toolCallId?}
```

- Required: `agent.describe`, `session.prompt`, `session.abort`, `session.messages`, `session.state`, `session.respond`. Everything else is optional and listed in `methods`.
- `message_end` carries an optional `entryId` so the paged-history covered-entries range works for every agent.
- `toolCallId` on prompts links a permission request to the tool call it is about.
- Session identity is a launch argument of `ox agent serve`, not a protocol field. The Host stores the `sessionRef` it was given.

## Host

```text
Conversation ──► AgentConnection
                   ├─ LocalAgent    pi-durable in JSContext; model/tool callbacks and crash-resume stay inside
                   └─ RemoteAgent   WebSocket JSON-RPC client

ox agent serve -- pi --mode rpc     envelope swap only
ox agent serve claude-code          claude -p stream-json → pi events and prompts
ox agent serve codex                Codex JSON output → pi events and prompts
```

- `AgentEvent` keeps its cases; `DurableAgentHost.receive` maps pi event names onto them for both connections.
- `resumeSubmission` moves inside `LocalAgent`. External agents resume through their own session.
- Model list for the picker comes from `models.list`. `LocalAgent` answers from the Host's providers, so one picker serves every agent.
- External conversations still use the durable DB for metadata, `ox.native.presentation` copies and read state, with no model entries.

## Client↔Host endpoints

```diff
  host.describe            unchanged
  conversations.new        + agent?               missing = .local
  conversations.open       + agent {name, machine, folder, status, methods[]}
  conversations.list       + agent per row
  conversations.respond    unchanged; promptId may come from an agent prompt
  providers.list           unchanged; Ox's own providers
+ agents.list              [{name, selection, machine, folder, status}]
+ agents.add               {name, endpoint}
+ agents.remove            {endpoint}
```

## UX

- Top bar: `ConversationModelButton` becomes `ConversationAgentButton`, showing agent icon + model name. No icon when Ox is the only agent. Accessibility label "Agent: <agent> on <machine>, model <model>". Identifier `conversation.modelPicker` becomes `conversation.agentPicker`.
- `ModelPickerSheet` becomes `AgentPickerSheet`: Agent section (shown when more than one agent exists, locked after the first send), Model from `models.list`, Thinking if supported, Region/Provider/Authentication for Ox only. Offline or logged-out agents are not selectable and say why.
- Settings: "Default model" becomes "Default agent". A new Agents page mirrors `HostPickerView`: Ox (local) first, remote agents with machine, folder and probe status, "Add Remote Agent".
- Sidebar: one list; agent icon on non-Ox rows; "Offline" label.
- Conversation with an external agent hides services, skills, schedules, files/canvas, secret entry, child chips, and edit/fork when `fork` is unsupported.
- Tool calls render generically: name, argument summary, result; edits through `DiffCodeBlockBody`; shell output as code.
- Agent prompts render as an inline card on the matching tool call and set `.permissionNeeded`, so background notifications work.
- Status text uses the agent's name ("Claude Code is thinking").
- Offline agent: read-only transcript, banner, composer disabled. Logged out: card with the login command for that machine.
- Agent icons live in `openox-service-assets-prod` with other service icons.

## File tree

```diff
  apps/shared/Host/Agent/
+   Connection/AgentConnection.swift
+   Connection/LocalAgent.swift
+   Connection/RemoteAgent.swift
  apps/shared/Platform/Models/
+   AgentConfiguration.swift
  apps/shared/Host/Durable/
    DurableConversation.swift            ~ agent calls move to LocalAgent
    DurableAgentHost.swift               ~ pi event names, agent_settled, entryId
  apps/shared/Host/Conversations/
    Conversation.swift                   ~ holds AgentConnection
    ConversationManager.swift            ~ creates with agent selection
    ConversationExecution.swift          ~ phase titles use agent name
  apps/shared/Host/RPC/
    ConversationCommands.swift           ~ new/open/respond route to the agent
    ConversationSnapshot.swift           ~ session.messages
+   AgentCommands.swift
  packages/agent/src/adapters/ios/agent.ts  ~ agent actions renamed to pi names
  packages/protocol/
    schema.json, methods.json            ~ agent on conversations, agents.*
+   agent-methods.json
  apps/cli/src/
+   agent-serve.ts
+   agent-list.ts
+   agents/claude-code.ts
+   agents/codex.ts
  apps/ios/Client/
-   Features/Conversation/ConversationModelButton.swift
+   Features/Conversation/ConversationAgentButton.swift
-   Features/Providers/ModelPickerSheet.swift
+   Features/Providers/AgentPickerSheet.swift
+   Features/Settings/AgentPickerView.swift
    Features/Settings/SettingsSheet.swift      ~ Default agent
    Features/Conversation/RequestCard.swift    ~ generic tool calls, agent prompts
    Features/Conversation/ConversationPage.swift  ~ hide Ox-only rows
    Automation/Accessibility.swift             ~ agentPicker, Agents IDs
```

## Send path

```diff
  conversations.send → ConversationCommands → Conversation.send → execution.submit
- → Conversation.submit → DurableRuntime.command("run")
+ → agent.send(.prompt)
+ ├─ LocalAgent → DurableRuntime.command("prompt") → pi-durable → nativeModel / nativeTool
+ └─ RemoteAgent → WebSocket → ox agent serve → pi / claude / codex
- → agentEvents → DurableAgentHost.receive → Conversation.receiveAgentEvent
+ → session.event → AgentEvent → Conversation.receive
  → ConversationDocument → Client stream
```

## Storage

```diff
  Profile durable DB
    conversation metadata
+     agent: .local | .remote(endpoint), sessionRef     missing = .local
    model entries                                       local agent only
    ox.native.presentation copies                       every agent
  App configuration
+   agentConfiguration.json  {format: 1, remoteAgents: [{name, endpoint}]}
```

Old conversations decode as `.local` and need no migration. A Host older than this change ignores the new fields; a remote conversation opened there must show as unavailable rather than run on the local agent.

## Order

1. Rename the local agent's actions and events to pi names. No behavior change.
2. Add `AgentConnection` and `LocalAgent`; rename the top-bar button and picker sheet. Ox is the only agent.
3. Add `ox agent serve` for pi, `RemoteAgent`, `agents.*`, the storage field, and the Agents settings page.
4. Add the Claude Code translator, then Codex; upload agent icons.
5. Update README, `OnboardingView.swift` and the website together.

Steps 1–2 touch the same files as the paged-history work and start after it lands.

## Open questions

- Exact `claude` flags for partial messages and permission prompts, and which Codex mode to translate; confirmed by a spike in step 4.
- Whether `ox agent serve` advertises itself for discovery the way Hosts do, or is added by endpoint only in v1.
- How an older Host should present a conversation whose agent it does not know.

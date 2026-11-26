# Agent interface

Status: proposed; no runtime changes. Separate Ox into Client, Host and Agent, so a Host conversation can run on Ox's built-in agent or on any agent elsewhere (pi, Claude Code, Codex) through one interface. Host↔Agent mirrors Client↔Host: a local in-process connection or a remote WebSocket JSON-RPC endpoint, and everything is a conversation.

## Problem

`Conversation` reaches pi-durable through `DurableConversation.swift` and one JavaScriptCore entry point that takes about 50 actions in `packages/agent/src/adapters/ios/agent.ts`. Those actions mix three concerns:

| Concern | Actions | Destination |
|---|---|---|
| Agent | `attach`, `run`, `continue`, `abort`, `resume`, `resumeExisting`, `conversationContext` | the agent interface |
| Context | `composePrompt`, per-turn sections, system updates | Host-composed for every agent |
| Host storage | `application*`, `conversationList/History/Present/Read/Record`, schedules, profile, `file*` | stays Host-internal for every conversation |
| Ox tool backends | `filesystem*`, `fileMounts`, `skillPackages`, `nativeModel`, `nativeTool` | stays inside the local agent |

Only the first row belongs to an agent. Because all three share one channel, no other agent can be plugged in.

## Goal

- One `AgentConnection` used by `Conversation` for every agent, built-in or not.
- Two connection kinds only: `.local` (built-in pi-durable in-process) and `.remote(endpoint)` (WebSocket JSON-RPC 2.0 to `ox agent serve`).
- One vocabulary: conversations. pi sessions, Claude Code sessions and Codex threads are all conversations; those words exist only inside translators.
- Conversations started in a terminal on the agent's machine appear in Ox.
- Every agent gets the same context and tools as the built-in agent: Ox's system prompt, memory, personal context, skills, attached services, and the `execute` tool with the full `ox.*` catalog, run on the Host.
- The Host notifies a Client whose app is closed, whatever the agent.
- Agent-specific translation lives in `ox agent serve`, never in the Host.
- With only the built-in agent configured, behavior and UI are unchanged.

Non-goals for v1: Ox-side compaction for external agents; switching agent within a conversation; live mirroring of a pi or Claude Code terminal while it is running.

## Mirror of Client↔Host

| Client↔Host | Host↔Agent |
|---|---|
| `HostSelection .local / .remote(endpoint:)` | `AgentSelection .local / .remote(endpoint:)`, per conversation |
| `HostConfiguration.remoteHosts` | `AgentConfiguration.remoteAgents [{name, endpoint}]`, stored on the Host |
| in-process `OxHost` | in-process built-in agent |
| WebSocket JSON-RPC 2.0, port 9876 | WebSocket JSON-RPC 2.0 to `ox agent serve`, port 9877 |
| `host.describe` | `agent.describe` |
| `conversations.*` | `conversations.*`, same names, agent-level payloads |
| `RemoteHostProbe` statuses | same statuses for agent rows |
| `HostProtocols.unsupported` | same for the `agent` protocol version |
| `OX_HOST_ENDPOINT`, `ox host list` | `OX_AGENT_ENDPOINT`, `ox agent list` |
| Tailscale, trusted network only | same |

An agent on the same Mac is remote at `ws://127.0.0.1:9877`. The macOS Host is sandboxed (`apps/macos/host.entitlements`), so only `ox agent serve` spawns processes.

## Protocol

Envelope is JSON-RPC 2.0 like Client↔Host. Payloads are pi's RPC events and pi-ai messages, which `DurableMessageCodec` already decodes. Methods are generated from `packages/protocol/agent-methods.json`.

```text
agent.describe              → implementation {name, version}, machine, folder, protocols {agent: [1]}, methods
models.list                 → models
conversations.list          → [{id, title, cwd, state: idle|running|blocked, origin: terminal|ox, updatedAt}]
conversations.new           {cwd?, model?, context, tools} → {id}
conversations.open          {id, context, tools} → {messages, state}   subscribes to its notifications
conversations.close         {id}
conversations.send          {id, text, images?, delivery?: steer|followUp, contextUpdate?} → {disposition}
conversations.stop          {id}
conversations.respond       {id, promptId, answer}
conversations.setModel      {id, provider, model}
conversations.setThinking   {id, level}
conversations.compact       {id}
conversations.rename        {id, title}
conversations.fork          {id, entryId} → {id}
notify conversations.event   {id, event}       agent_start, agent_settled, turn_*, message_*, tool_execution_*, compaction_*, queue_update
notify conversations.prompt  {id, promptId, method: confirm|select|input|editor, title, options?, toolCallId?}
notify conversations.changed {id, state, title}
request tools.call           {id, toolCallId, name, args} → result     agent → Host on the same WebSocket
notify tools.progress        {id, toolCallId, message}
```

- Required: `agent.describe`, `conversations.list/new/open/send/stop/respond`. Everything else is optional and listed in `methods`.
- `id` is the agent's own conversation identity (pi session ID, Claude Code session ID, Codex thread ID). The Host keeps its own conversation ID and stores the agent's next to it.
- `message_end` carries an optional `entryId` so the paged-history covered-entries range works for every agent.
- `toolCallId` on prompts links a permission request to the tool call it is about.
- `context` is the composed Ox system prompt; `contextUpdate` is a rendered system update sent only when per-turn sections or memory changed since the last send.
- `tools` is the manifest of Host tools (today only `execute`, with its catalog description).

## Translators

| | pi | Claude Code | Codex |
|---|---|---|---|
| Run | one `pi --mode rpc --session <id>` per open conversation | one `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --resume <id> --permission-prompts host` per open conversation | client of the shared `codex app-server` daemon |
| `conversations.list` | session files in `~/.pi/agent/sessions` | `claude agents --json` | `thread/list`, `thread/loaded/list` |
| `send` / `stop` | `prompt`, `steer`, `follow_up` / `abort` | stdin `user` / interrupt control request | `turn/start`, `turn/steer` / `turn/interrupt` |
| `open` messages | `get_messages` | session JSONL on disk | `thread/read`, `thread/items/list` |
| Prompts | extension UI dialogs | permission control requests | `item/*/requestApproval`, `item/tool/requestUserInput` |
| Busy in a terminal | read-only until idle | read-only until idle | live, as another client of the same thread |
| Ox context | `--append-system-prompt`; updates prefixed to the next prompt | `--append-system-prompt`; updates prefixed to the next user message | `developerInstructions` on `thread/start`; updates via `thread/inject_items` |
| Ox tools | MCP server registered for the process | `--mcp-config`, `--allowedTools mcp__ox__execute` | MCP server in the thread `config`, approval policy allows it |
| Unattended trust | `--approve` / `--no-approve` per agent entry | `--permission-mode` per agent entry | `--sandbox`, `--ask-for-approval` per agent entry |

Translators call binaries directly, never through shell aliases.

## Context and tools

The Host composes context and runs tools for every agent, so a remote agent sees what the built-in agent sees.

- Context: `composePrompt` moves from the local agent to the Host. The same system prompt (preamble, rules, memory, personal context) and per-turn sections (skills, attached services, host context, reply format, response language) are rendered for every agent. The local agent keeps receiving them as its system prompt and system updates; a remote agent gets the system prompt appended to its own and updates rendered with the same `renderSystemMessageUpdate` format ahead of the next user message.
- Tools: `ox agent serve` runs a per-conversation MCP server (streamable HTTP on loopback, per-conversation token) exposing `execute`. Each call becomes `tools.call` to the Host, which runs `ConversationTool.execute` in that conversation's VM. Same functions, limits, approvals and invocation cards as the built-in agent; secrets resolve on the Host and never reach the agent.
- Two file systems: the agent's own tools act on its machine, `ox.fs` acts on Ox files on the Host. The context names both; skill files are read through `execute`.
- Translators pre-allow the Ox MCP tool so Ox's checks are the only approval, and set agent-side tool timeouts above the VM timeout, with `tools.progress` while a call waits on the user.
- If the Host is unavailable mid-run, `tools.call` fails fast with "Ox Host is unavailable" and the agent continues without Ox tools.
- Memory and personal context reach whichever model provider the remote agent uses, as they reach the Host's provider today.

## Host

```text
Conversation ──► AgentConnection
                   ├─ LocalAgent    pi-durable in JSContext; model/tool callbacks and crash-resume stay inside
                   └─ RemoteAgent   WebSocket JSON-RPC client
```

- `AgentEvent` keeps its cases; pi event names map onto them for both connections.
- `resumeSubmission` moves inside `LocalAgent`. External agents resume through their own conversation.
- `RemoteAgent` answers `tools.call` with the conversation's `ConversationTool` and shows one execute card per call, matched by `toolCallId`.
- Model list for the picker comes from `models.list`. `LocalAgent` answers from the Host's providers, so one picker serves every agent.
- External conversations still use the durable DB for metadata, `ox.native.presentation` copies and read state, with no model entries.
- Agent conversations not yet known to the Host show under their agent and become Host conversations when opened.

## Notifications

The Host is the only sender. Agents and `ox agent serve` know nothing about notifications.

- Trigger: a conversation enters `.permissionNeeded`, `.inputNeeded`, `.loginNeeded`, `.failed` or completes, and no connected Client has it open.
- Delivery: Host → OpenOx push relay → APNs for iOS, FCM later for Android. The relay holds the APNs key, forwards ciphertext, and keeps no payloads.
- Each Client registers with each Host it uses: `notifications.register {pushToken, platform, environment, key, kinds[]}`, again on every launch, and `notifications.unregister` on removal.
- Payloads are encrypted with the Client's key. An iOS Notification Service Extension decrypts them with the key from an app-group Keychain item, and falls back to "Ox needs your attention".
- Approval notifications carry Approve and Deny actions that answer through `conversations.respond`. They show a shortened command, never full tool arguments.
- One thread per conversation; a collapse ID makes a newer state replace an older one.
- An iPhone Host is suspended while the app is closed, so it keeps today's local notifications only. Closed-app pushes need an always-on Host such as the Mac.

## Client↔Host endpoints

```diff
  host.describe              unchanged
  conversations.new          + agent?                 missing = .local
  conversations.open         + agent {name, machine, folder, status, methods[]}
  conversations.list         + agent per row
  conversations.respond      unchanged; promptId may come from an agent prompt
  providers.list             unchanged; Ox's own providers
+ agents.list                [{name, selection, machine, folder, status}]
+ agents.add                 {name, endpoint, trust}
+ agents.remove              {endpoint}
+ agents.conversations       {endpoint} → agent conversations not yet in the Host
+ notifications.register     {pushToken, platform, environment, key, kinds[]}
+ notifications.unregister   {pushToken}
```

## UX

- Top bar: `ConversationModelButton` becomes `ConversationAgentButton`, showing agent icon + model name. No icon when Ox is the only agent. Accessibility label "Agent: <agent> on <machine>, model <model>". Identifier `conversation.modelPicker` becomes `conversation.agentPicker`.
- `ModelPickerSheet` becomes `AgentPickerSheet`: Agent section (shown when more than one agent exists, locked after the first send), Model from `models.list`, Thinking if supported, Region/Provider/Authentication for Ox only. Offline or logged-out agents are not selectable and say why.
- Settings: "Default model" becomes "Default agent". A new Agents page mirrors `HostPickerView`: Ox (local) first, remote agents with machine, folder and probe status, "Add Remote Agent". Notifications lists which kinds to push.
- Sidebar: one list; agent icon on non-Ox rows; "Offline" label. Each remote agent can show its terminal conversations with their state.
- Conversation busy in a terminal: "Running in Terminal" banner and read-only transcript until it is idle, except Codex, which is live.
- Conversation with an external agent hides services, skills, schedules, files/canvas, secret entry, child chips, and edit/fork when `fork` is unsupported.
- Tool calls render generically: name, argument summary, result; edits through `DiffCodeBlockBody`; shell output as code; Codex plans as a checklist.
- Agent prompts render as an inline card on the matching tool call and set `.permissionNeeded`.
- Composer: `/` suggestions from the agent's commands; long-press send for follow-up; queued messages as chips.
- Status text uses the agent's name ("Claude Code is thinking").
- Offline agent: read-only transcript, banner, composer disabled. Logged out: card with the login command for that machine.
- Agent icons live in `openox-service-assets-prod` with other service icons.

## File tree

```diff
  apps/shared/Host/Agent/
+   Connection/AgentConnection.swift
+   Connection/LocalAgent.swift
+   Connection/RemoteAgent.swift
+   AgentContext composition moved from packages/agent to a Host-level composer used by both connections
  apps/shared/Host/Notifications/
+   PushNotifier.swift                   phase change + no watcher → relay
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
    ConversationSnapshot.swift           ~ conversations.open messages
+   AgentCommands.swift
+   NotificationCommands.swift
  packages/agent/src/adapters/ios/agent.ts  ~ agent actions renamed to pi names
  packages/protocol/
    schema.json, methods.json            ~ agent on conversations, agents.*, notifications.*
+   agent-methods.json
  apps/cli/src/
+   agent-serve.ts
+   agent-list.ts
+   agents/pi.ts
+   agents/claude-code.ts
+   agents/codex.ts
+   agent-tools-mcp.ts                     per-conversation MCP server → tools.call
  apps/ios/
+   NotificationService/                 Notification Service Extension target
    ios.entitlements                     ~ aps-environment
  apps/ios/Client/
-   Features/Conversation/ConversationModelButton.swift
+   Features/Conversation/ConversationAgentButton.swift
-   Features/Providers/ModelPickerSheet.swift
+   Features/Providers/AgentPickerSheet.swift
+   Features/Settings/AgentPickerView.swift
    Features/Settings/SettingsSheet.swift      ~ Default agent, notification kinds
    Features/Conversation/RequestCard.swift    ~ generic tool calls, agent prompts
    Features/Conversation/ConversationPage.swift  ~ hide Ox-only rows, terminal banner
    Automation/Accessibility.swift             ~ agentPicker, Agents IDs
+ push relay (hosted)
```

## Send path

```diff
  conversations.send → ConversationCommands → Conversation.send → execution.submit
- → Conversation.submit → DurableRuntime.command("run")
+ → agent.send(.prompt)
+ ├─ LocalAgent → DurableRuntime.command("prompt") → pi-durable → nativeModel / nativeTool
+ └─ RemoteAgent → WebSocket → ox agent serve → pi / claude / codex
- → agentEvents → DurableAgentHost.receive → Conversation.receiveAgentEvent
+ → conversations.event → AgentEvent → Conversation.receive
  → ConversationDocument → Client stream
+ → agent calls mcp__ox__execute → ox agent serve → tools.call → ConversationTool.execute (Host VM) → result
+ → phase change, no watcher → PushNotifier → relay → APNs → Notification Service Extension
```

## Storage

```diff
  Profile durable DB
    conversation metadata
+     agent: .local | .remote(endpoint), agentConversationID     missing = .local
    model entries                                               local agent only
    ox.native.presentation copies                               every agent
  App configuration
+   agentConfiguration.json         {format: 1, remoteAgents: [{name, endpoint, trust}]}
+   notificationRegistrations.json  {format: 1, clients: [{pushToken, platform, environment, keyRef, kinds}]}
  iOS app group Keychain
+   per-Client notification key, shared with the Notification Service Extension
```

Old conversations decode as `.local` and need no migration. A Host older than this change ignores the new fields; a remote conversation opened there must show as unavailable rather than run on the local agent. The notification key is stored by reference, never in plain configuration.

## Order

1. Rename the local agent's actions and events to pi names. No behavior change.
2. Add `AgentConnection` and `LocalAgent`; rename the top-bar button and picker sheet. Ox is the only agent.
3. Add `ox agent serve` with the Codex translator, `RemoteAgent`, `agents.*`, the storage field, the Agents settings page, Host-composed context, and the `tools.call` MCP bridge, so parity ships with the first remote agent.
4. Add the pi and Claude Code translators; upload agent icons.
5. Add the push relay, `PushNotifier`, `notifications.*`, and the Notification Service Extension.
6. Update README, `OnboardingView.swift` and the website together.

## Open questions

- Exact Claude Code control requests (interrupt, permission, set model) and `stream_event` shapes; whether Codex's terminal UI always uses the shared daemon. Confirmed by a spike in step 3–4.
- How Ox's preamble and rules sit next to each agent's own system prompt (identity, reply style) without conflict; checked per translator in the spike.
- Where the relay runs, and how it limits who can send to a token (pairing secret, rate limits, App Attest).
- Whether `ox agent serve` advertises itself for discovery the way Hosts do, or is added by endpoint only in v1.
- How an older Host should present a conversation whose agent it does not know.

# Agent interface

Status: proposed; no runtime changes. Separate Ox into Client, Host and Agent, so a Host conversation can run on Ox's built-in agent or on pi running on another machine, through one interface. Host↔Agent mirrors Client↔Host: a local in-process connection or a remote WebSocket JSON-RPC endpoint, and everything is a conversation.

## Problem

`Conversation` reaches pi-durable through `DurableConversation.swift` and one JavaScriptCore entry point that takes about 50 actions in `packages/agent/src/adapters/ios/agent.ts`. Those actions mix four concerns:

| Concern | Actions | Destination |
|---|---|---|
| Agent | `attach`, `run`, `continue`, `abort`, `resume`, `resumeExisting`, `conversationContext` | the agent interface |
| Context | `composePrompt`, per-turn sections, system updates | Host-composed for every agent |
| Host storage | `application*`, `conversationList/History/Present/Read/Record`, schedules, profile, `file*` | stays Host-internal for every conversation |
| Ox tool backends | `filesystem*`, `fileMounts`, `skillPackages`, `nativeModel`, `nativeTool` | stays on the Host, reachable from every agent |

Only the first row belongs to an agent. Because all four share one channel, no other agent can be plugged in.

## Goal

- One `AgentConnection` used by `Conversation` for every agent.
- Two connection kinds only: `.local` (built-in pi-durable in-process) and `.remote(endpoint)` (WebSocket JSON-RPC 2.0 to `ox agent serve`, which runs pi).
- One agent family: pi. The built-in agent is pi-durable; the remote agent is pi in RPC mode. Both emit pi-agent-core events and pi-ai messages, so the Host decodes one format.
- Model choice lives inside pi. A remote pi offers whatever its machine has configured, including Claude subscription models through pi-claude-code and ChatGPT/Codex subscription models through pi-ai's OpenAI providers.
- One vocabulary: conversations. pi sessions are conversations; the word exists only inside `ox agent serve`.
- A remote pi gets the same context and tools as the built-in agent: Ox's system prompt, memory, personal context, skills, attached services, per-turn updates, and the `execute` tool with the full `ox.*` catalog, run on the Host.
- The Host notifies a Client whose app is closed, whatever the agent.
- With only the built-in agent configured, behavior and UI are unchanged.

Non-goals for v1: Claude Code or Codex as agents that run their own loop; live mirroring of a pi terminal session while it runs; Ox-side compaction for remote conversations.

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
models.list                 → pi's available models
conversations.list          → [{id, title, cwd, state: idle|running, origin: terminal|ox, updatedAt}]
conversations.new           {cwd?, model?, context, tools} → {id}
conversations.open          {id, context, tools} → {messages, state}   subscribes to its notifications
conversations.close         {id}
conversations.send          {id, text, images?, delivery?: steer|followUp, context?} → {disposition}
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

- Required: `agent.describe`, `conversations.list/new/open/send/stop/respond`, `tools.call`. Everything else is optional and listed in `methods`.
- `id` is the pi session ID. The Host keeps its own conversation ID and stores pi's next to it.
- `context` carries Ox's system prompt and per-turn sections; `send` includes it only when it changed since the last send.
- `tools` is the manifest of Host tools (today only `execute`, with its catalog description).
- `message_end` carries an optional `entryId` so the paged-history covered-entries range works for remote conversations.
- `toolCallId` on prompts links a permission request to the tool call it is about.

## ox agent serve

```text
ox agent serve [--port 9877] [--cwd <folder>] [--approve | --no-approve]
  per open conversation: pi --mode rpc --session <id> -e <ox pi extension>
  conversations.list: pi session files for the folder (~/.pi/agent/sessions)
  conversations.* ↔ pi RPC commands: prompt, steer, follow_up, abort, get_messages, set_model,
                    set_thinking_level, compact, set_session_name, fork; extension UI ↔ prompts
```

- Calls `pi` directly, never through shell aliases.
- Closes a pi process after the conversation has been idle and unsubscribed for a while, and resumes it with `--session` on the next `open`.
- A session that a terminal pi is writing is read-only in Ox until it is idle.

## Context and tools

The Host composes context and runs tools for every agent. For a remote pi, a small Ox extension loaded with `-e` carries both, so pi treats them exactly as pi-durable does.

- Context: `composePrompt` moves from the local agent to the Host. The same system prompt (preamble, rules, memory, personal context) and per-turn sections (skills, attached services, host context, reply format, response language) are rendered for every agent. The extension writes them into `systemPromptOptions.sections` in `before_agent_start`; pi diffs the sections and appends one system patch, the same system-update mechanism the built-in agent uses through pi-ai.
- Tools: the extension registers `execute` with `pi.registerTool`. Each call becomes `tools.call` to the Host, which runs `ConversationTool.execute` in that conversation's VM. Same functions, limits, approvals and invocation cards as the built-in agent; secrets resolve on the Host and never reach the agent's machine.
- Two file systems: pi's own tools (`read`, `bash`, `edit`, `write`, `grep`, `find`, `ls`) act on its machine, `ox.fs` acts on Ox files on the Host. The context names both; skill files are read through `execute`.
- While a call waits on the user (`ox.user.choose`), the extension streams `tools.progress` through pi's tool update callback.
- If the Host is unavailable mid-run, `tools.call` fails fast with "Ox Host is unavailable" and pi continues without Ox tools.
- Memory and personal context reach whichever model provider the remote pi uses, as they reach the Host's provider today.

## Host

```text
Conversation ──► AgentConnection
                   ├─ LocalAgent    pi-durable in JSContext; model/tool callbacks and crash-resume stay inside
                   └─ RemoteAgent   WebSocket JSON-RPC client to ox agent serve
```

- `AgentEvent` keeps its cases; pi event names map onto them for both connections.
- `resumeSubmission` moves inside `LocalAgent`. Remote conversations resume through their pi session.
- Model list for the picker comes from `models.list`. `LocalAgent` answers from the Host's providers, so one picker serves both.
- `RemoteAgent` answers `tools.call` with the conversation's `ConversationTool` and shows one execute card per call, matched by `toolCallId`.
- Remote conversations still use the durable DB for metadata, `ox.native.presentation` copies and read state, with no model entries.
- pi sessions not yet known to the Host show under their agent and become Host conversations when opened.

## Notifications

The Host is the only sender. pi and `ox agent serve` know nothing about notifications.

- Trigger: a conversation enters `.permissionNeeded`, `.inputNeeded`, `.loginNeeded`, `.paymentNeeded`, `.failed` or completes, and no connected Client has it open.
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
+ agents.add                 {name, endpoint}
+ agents.remove              {endpoint}
+ agents.conversations       {endpoint} → pi sessions not yet in the Host
+ notifications.register     {pushToken, platform, environment, key, kinds[]}
+ notifications.unregister   {pushToken}
```

## UX

- Top bar: `ConversationModelButton` becomes `ConversationAgentButton`, showing agent icon + model name. No icon when Ox is the only agent. Accessibility label "Agent: <agent> on <machine>, model <model>". Identifier `conversation.modelPicker` becomes `conversation.agentPicker`.
- `ModelPickerSheet` becomes `AgentPickerSheet`: Agent section (shown when more than one agent exists, locked after the first send), Model from `models.list` grouped by provider, Thinking if supported, Region/Provider/Authentication for Ox only. Offline or logged-out agents are not selectable and say why.
- Settings: "Default model" becomes "Default agent". A new Agents page mirrors `HostPickerView`: Ox (local) first, remote agents with machine, folder and probe status, "Add Remote Agent". Notifications lists which kinds to push.
- Sidebar: one list; agent icon on non-Ox rows; "Offline" label. Each remote agent can show its pi sessions started in a terminal.
- Session busy in a terminal: "Running in Terminal" banner and read-only transcript until it is idle.
- A remote conversation hides child chips and edit/fork when `fork` is unsupported; services, skills, schedules, files and secrets stay, since they run on the Host.
- pi's tool calls render generically: name, argument summary, result; `edit` through `DiffCodeBlockBody`; `bash` output as code; `read`, `grep`, `find`, `ls` as one-line rows. Ox's `execute` keeps its own card.
- Agent prompts render as an inline card on the matching tool call and set `.permissionNeeded`.
- Composer: `/` suggestions from pi's commands; long-press send for follow-up; queued messages as chips.
- Status text uses the agent's name ("pi is thinking").
- Offline agent: read-only transcript, banner, composer disabled. Logged out of a provider: card with the login command for that machine. Overage reported by pi-claude-code: `.paymentNeeded`.
- The pi icon lives in `openox-service-assets-prod` with other service icons.

## File tree

```diff
  apps/shared/Host/Agent/
+   Connection/AgentConnection.swift
+   Connection/LocalAgent.swift
+   Connection/RemoteAgent.swift
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
  packages/agent/src/
    adapters/ios/agent.ts                ~ agent actions renamed to pi names; composePrompt exposed to the Host
  packages/protocol/
    schema.json, methods.json            ~ agent on conversations, agents.*, notifications.*
+   agent-methods.json
  apps/cli/src/
+   agent-serve.ts                         WebSocket server, pi process per conversation
+   agent-pi-extension.ts                  context sections + execute → tools.call
+   agent-list.ts
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
    Features/Conversation/RequestCard.swift    ~ pi tool calls, agent prompts
    Features/Conversation/ConversationPage.swift  ~ terminal banner
    Automation/Accessibility.swift             ~ agentPicker, Agents IDs
+ push relay (hosted)
```

## Send path

```diff
  conversations.send → ConversationCommands → Conversation.send → execution.submit
- → Conversation.submit → DurableRuntime.command("run")
+ → agent.send(.prompt)
+ ├─ LocalAgent → DurableRuntime.command("prompt") → pi-durable → nativeModel / nativeTool
+ └─ RemoteAgent → WebSocket → ox agent serve → pi --mode rpc (+ Ox extension) → pi's provider
- → agentEvents → DurableAgentHost.receive → Conversation.receiveAgentEvent
+ → conversations.event → AgentEvent → Conversation.receive
  → ConversationDocument → Client stream
+ → pi calls execute → Ox extension → tools.call → ConversationTool.execute (Host VM) → result
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
+   agentConfiguration.json         {format: 1, remoteAgents: [{name, endpoint}]}
+   notificationRegistrations.json  {format: 1, clients: [{pushToken, platform, environment, keyRef, kinds}]}
  iOS app group Keychain
+   per-Client notification key, shared with the Notification Service Extension
```

Old conversations decode as `.local` and need no migration. A Host older than this change ignores the new fields; a remote conversation opened there must show as unavailable rather than run on the local agent. The notification key is stored by reference, never in plain configuration.

## Order

1. Rename the local agent's actions and events to pi names. No behavior change.
2. Add `AgentConnection` and `LocalAgent`; move `composePrompt` behind a Host composer; rename the top-bar button and picker sheet. Ox is the only agent.
3. Add `ox agent serve` with pi and the Ox pi extension (context and `execute`), `RemoteAgent`, `agents.*`, the storage field, and the Agents settings page. Parity ships with the first remote agent.
4. Verify Claude subscription models through pi-claude-code and ChatGPT/Codex models through pi-ai on a remote pi; upload the pi icon.
5. Add the push relay, `PushNotifier`, `notifications.*`, and the Notification Service Extension.
6. Update README, `OnboardingView.swift` and the website together.

Later, if wanted: let the built-in agent use a remote machine's pi providers (for example the Claude subscription) through a model-streaming method on `ox agent serve`, keeping the conversation local and durable.

## Open questions

- Whether a remote pi keeps its default coding prompt with Ox's sections added, or Ox's prompt replaces it (`forceSystemPrompt`) with a short note about pi's machine tools.
- Where the relay runs, and how it limits who can send to a token (pairing secret, rate limits, App Attest).
- Whether `ox agent serve` advertises itself for discovery the way Hosts do, or is added by endpoint only in v1.
- Whether loading the Ox extension in a terminal pi should later report that session live to `ox agent serve`.
- Anthropic's announced and paused change to how `claude -p` subscription use is billed, which pi-claude-code depends on.
- How an older Host should present a conversation whose agent it does not know.

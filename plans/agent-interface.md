# Agent interface

Status: steps 2–4 implemented and verified end to end with pi on a Mac and an iOS simulator Host; steps 1, 5 and 6 open (see Implementation status). Separate Ox into Client, Host and Agent, so a Host conversation can run on Ox's built-in agent or on pi running on another machine, through one interface. Host↔Agent mirrors Client↔Host: a local in-process connection or a remote WebSocket JSON-RPC endpoint, and everything is a conversation.

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

An agent on the same Mac is remote at `ws://127.0.0.1:9877`. The macOS Host is sandboxed (`apps/macos/mac.entitlements`), so only `ox agent serve` spawns processes.

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
ox agent serve [--port 9877] [--approve | --no-approve]
  per open conversation: pi --mode rpc --session <id> -e <ox pi extension>
  conversations.list: every pi session file (~/.pi/agent/sessions)
  conversations.* ↔ pi RPC commands: prompt, steer, follow_up, abort, get_messages, set_model,
                    set_thinking_level, compact, set_session_name, fork; extension UI ↔ prompts
```

- Calls `pi` directly, never through shell aliases.
- Closes a pi process after the conversation has been idle and unsubscribed for a while, and resumes it with `--session` on the next `open`.
- A session that a terminal pi is writing is read-only in Ox until it is idle.

## Context and tools

The Host composes context and runs tools for every agent. For a remote pi, a small Ox extension loaded with `-e` carries both, so pi treats them exactly as pi-durable does.

- Context: `composePrompt` moves from the local agent to the Host. The same system prompt (preamble, rules, memory, personal context) and per-turn sections (skills, attached services, host context, reply format, response language) are rendered for every agent. A remote pi keeps its default coding prompt; the extension adds Ox's sections to `systemPromptOptions.sections` in `before_agent_start` and never sets `forceSystemPrompt`; pi diffs the sections and appends one system patch, the same system-update mechanism the built-in agent uses through pi-ai.
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

## Boundaries and roadmap

Client → Profile (on a device) → Agent. Host is no longer a concept: what it owned folds into the Profile, and what is left is the Ox app's runtime on a device and the address a Client uses to reach it. Code keeps its Host names where they are plumbing; the `host.*` methods, `ox --host` and `OX_HOST_ENDPOINT` stay as "the address of an Ox app".

```diff
  Role     owns
  Client   UI state only; any Ox UI or the ox CLI
  Profile  memory, skills, conversations, files, policy, services, providers, remote agents;
           device-bound values (secrets, website logins, folder grants) scoped to it but stored on the device
  device   the app's runtime for the active Profile (VM, web views), ingress, push, "allow connections"
  Agent    the loop and its machine's limits: tools, macOS permissions
```

A device serves one active Profile at a time, so a remote Client opens that Profile or asks before switching it. A Profile synced to several devices has one writer at a time.

Agent machine limits:

```diff
  folders               none; pi runs as the Mac's user, and a conversation starts in its home folder or a cwd the Host names
+ conversations.new     result + cwd; the Host stores it on RemoteAgentBinding
  tools                 pi's own defaults; no agent-side tool permissions for now
```

The built-in agent gets no shell; it delegates shell work with `ox.conversation.start({ agent })`. A per-conversation tool selection and approval prompts were built and removed (reverting c6bc1f3c); pi's `pi.setActiveTools` and a `tool_call` handler calling `ctx.ui.confirm` are the hooks if this returns. A remote machine's folders are not mounted into `ox.fs` for now.

Device-bound values belong to a Profile but stay in device storage, keyed by `profileId`; the Profile folder holds only names and IDs, since it can be synced or exported.

```diff
  item                    today                                  after
  secrets, provider keys, Keychain "secret:<k>", "api:<p>",      Keychain "<profileId>/secret:<k>", "<profileId>/api:<p>", ...
  subscription and          "oauth:mcp:…", app-wide              device-wide accounts (push key, ingress) keep their names
  MCP tokens
  website logins          one WKWebsiteDataStore, UUID from      the existing store is kept for the current Profile;
                          the website-data namespace             other Profiles get UUIDs from namespace + profileId
  folder grants           device-folder-grants.json + profileId  unchanged
  mounted repositories    app-level paths                        keyed by profileId
  policy, services, providers, remote agents  app Configuration/  Profile
  ingress, push, VM       device                                 device
```

Migration assigns everything existing to the Profile selected at upgrade. Keychain accounts move with the existing `CredentialMigrator` pattern: write the prefixed account, read it back, then delete the old one. Website data needs no copy: the current Profile keeps the existing store.

Website data moves between Profiles and devices with `WKWebsiteDataStore.fetchData(of:)` and `restoreData(_:)` (iOS 26, macOS 26, within the deployment targets). The blob is opaque and holds session cookies, so it is a secret: it never goes into the Profile folder in plain form, only into an encrypted Profile export. Which data types it carries, and whether a blob restores on another device, must be verified on a device before relying on it; otherwise opening a Profile elsewhere asks to sign in again. Deleting a Profile removes its store with `WKWebsiteDataStore.remove(forIdentifier:)` and its Keychain accounts, after confirmation.

Order:

1. Done: `cwd` in `conversations.new`; authorized folders removed.
2. Dropped for now: agent-side tool permissions.
3. Done: per-Profile secrets (prefixed Keychain accounts) and website logins (store per Profile), migrated to the Profile selected at upgrade.
4. Website data export and import with `fetchData`/`restoreData`, after a device check of what restores.
5. Done: policy, services, providers and remote agents live in `<Profile>/.ox/`, migrated to the Profile selected at upgrade.
6. Done: drop Host from the UI and docs. Settings has a Device row (this device or another device running Ox, shown as "<active Profile> · <device>" from host.describe's new device and profile fields) and Allow connections; the Mac app is "Ox"; CLI help, README and the website's privacy and support pages describe devices and Profiles. No code or protocol rename.

## Notifications

The Host notifies locally while it runs. `ox agent serve` sends a push when no Host is subscribed to a conversation, because an iPhone Host is suspended while the app is closed.

- Trigger: an unwatched remote conversation completes (body is the last reply), raises a prompt, or its pi process exits with an error.
- Delivery: `ox agent serve` → push relay → APNs. The relay is one Lambda behind a Function URL in the private deploy repo; it holds the APNs key in Secrets Manager, forwards ciphertext, and stores nothing.
- The iOS Host registers its device token and key with each remote agent: `notifications.register {token, environment, key, kinds[]}` after each successful refresh, and `notifications.unregister` when the agent is removed. The agent keeps them in `push.json` (mode 0600).
- Payloads are sealed with AES-256-GCM using the device key. The Notification Service Extension opens them with the key from the app-group Keychain and falls back to "Ox needs your attention".
- One thread and collapse ID per conversation, so a newer state replaces an older one.
- A suspended Host stops answering WebSocket pings; serve drops it after 30 s of silence, and pushes start from then.
- Later: Approve and Deny actions, tap-to-open, App Attest for the relay.

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
  apps/shared/Runtime/Agent/
+   Connection/AgentConnection.swift
+   Connection/LocalAgent.swift
+   Connection/RemoteAgent.swift
  apps/shared/Runtime/Notifications/
+   PushNotifier.swift                   phase change + no watcher → relay
  apps/shared/Platform/Models/
+   AgentConfiguration.swift
  apps/shared/Runtime/Durable/
    DurableConversation.swift            ~ agent calls move to LocalAgent
    DurableAgentHost.swift               ~ pi event names, agent_settled, entryId
  apps/shared/Runtime/Conversations/
    Conversation.swift                   ~ holds AgentConnection
    ConversationManager.swift            ~ creates with agent selection
    ConversationExecution.swift          ~ phase titles use agent name
  apps/shared/Runtime/RPC/
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

- Where the relay runs, and how it limits who can send to a token (pairing secret, rate limits, App Attest).
- Whether `ox agent serve` advertises itself for discovery the way Hosts do, or is added by endpoint only in v1.
- Whether loading the Ox extension in a terminal pi should later report that session live to `ox agent serve`.
- Anthropic's announced and paused change to how `claude -p` subscription use is billed, which pi-claude-code depends on.
- How an older Host should present a conversation whose agent it does not know.

## Implementation status

- Shipped: `AgentConnection` split as `Conversation.submit` → `submitRemote` for remote bindings; `RemoteAgentClient` (WebSocket JSON-RPC), `RemoteAgentDirectory` (`remote-agents.json`, probe status, models, default agent); `RemoteAgentEvents` maps pi RPC events onto `AgentEvent` using the `AssistantPartial` stream shared with `DurableAgentHost`; `composeContext` renders Ox sections for remote pi; `execute` runs on the Host through `tools.call`; `agents.*` and `agentEndpoint` on `conversations.new`; `ox agent serve`, `ox agent describe`, `ox host agents`, `ox conversation new --agent`; agent button, `AgentPickerSheet`, Settings → Agents and Default agent, sidebar marker; branch, retry and edit hidden for remote conversations.
- Ox sections are sent to pi as `ox_<key>`: pi rejects a custom `preamble` section and would replace its own `rules` and `skills`.
- Remote turns are recorded as `ox.native.turn` entries after each run, because the projection restores turns only from entries that carry model messages.
- Step 1 (renaming the local agent's actions to pi names) was skipped: both connections already meet at `AgentEvent`, and the rename would only churn the durable bridge.
- Security: `ox agent serve` binds `127.0.0.1` and publishes `wss://<mac>.ts.net:9878` with a foreground `tailscale serve`; only the Tailscale user who owns the Mac, or local loopback callers without forwarding headers, are admitted. Raw tailnet binding was removed.
- Folders: no authorized folders; `agent.describe` reports `cwd`, the user's home folder, where a conversation without `cwd` runs; any existing folder is accepted as `cwd`; the agent tells pi its working folder each turn; the agent sheet shows the folder read-only.
- Storage: pi's session files are the only record of conversations; the agent lists every one, and a conversation it starts carries an `ox.origin` custom entry so `origin` survives restarts.
- Children: `ox.conversation.start({ agent, folder })` runs a child conversation on a remote agent, so an Ox conversation (or a remote pi) can delegate to pi on another machine.
- Catch-up: events carry `seq`; when the socket drops mid-run the Host retries for up to 10 minutes and reopens with `since`, replaying missed events. A gap on an idle conversation, or a serve restart, ends the run with a notice.
- Keep-awake: serve holds `caffeinate -i -w <pid>` on macOS unless `--allow-sleep`.
- Open: agent names in background phase titles, opening or forking a terminal-started pi session as a Host conversation (listing works through `agents.conversations`), terminal presence, reading agent-side files from the Client, a `tools.cancel` notification, catch-up after the Host app is relaunched mid-run, and README/onboarding/website copy.

## Retiring pi-manager

pi-manager exposes pi to an Ox conversation as MCP tools; `ox agent serve` plus agent child conversations covers that with visible, steerable conversations. Remaining pi-manager features to port first: terminal presence and forking external sessions, `read_file`/`read_attachment`, the multi-machine dashboard, and the menu bar app.

## tailcat

tailcat (Tailscale's data plane without its control plane: a secret address plus `--allow` node keys, NAT traversal, no accounts) was evaluated as the transport. It does not simplify v1: the iPhone Client and Host would have to embed tailcat's Go networking stack to dial it, Ox already depends on Tailscale for Host access, and Tailscale Serve already gives a trusted TLS name and per-user identity with no app-side code. It becomes worth revisiting if Ox needs to work without a Tailscale account; then `ox agent serve` could run behind `tailcat serve` and the app would add a tailcat client library.


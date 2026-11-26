---
name: ox-cli
description: Use the terminal as an Ox Client. Connect to a Profile open in Ox; discover, drive, inspect, or watch conversations; list model providers; read structured logs; inspect or call a VM; administer Profiles; inspect or verify service repositories; and invoke live services.
---

# Ox CLI

`ox` is a terminal Client. Check `ox --help` and the relevant action’s `--help`. Commands stay two levels deep: `ox <namespace> <action>`.

## Choose a Profile and resource

Run `ox profile discover` to discover simulators and Tailscale peers with a Profile open in Ox (`--all` includes unavailable candidates). For live work, select the intended Profile with `--profile <ws-url>` or `OX_PROFILE_ENDPOINT`. A connection reaches only the Profile active on that device, and only while its Allow Connections is on. A `ws://` endpoint without a port uses 9876; `wss://` uses 443. For simulator UI work, follow [simulator setup](../setup/references/simulator.md) and use the reserved device’s explicit UDID.

| Resource | Selector and use |
| --- | --- |
| `profile` | `--profile <ws-url>` for the open Profile's status (`describe`), providers, agents, logs, memory, and name; `--profile <path>` for offline read-only inspection of a Profile folder. Without a selector, `OX_PROFILE_ENDPOINT` selects the open Profile. |
| `conversation`, `vm` | `--profile <ws-url>` and `--conversation <full-id>` for a conversation and its actual VM. Don’t rely on the active conversation when another is intended. |
| `repository` | `--repository <path-or-url>` for offline inspection and validation; `list`, `connect`, and `disconnect` manage the open Profile's connections. |
| `service`, `files` | `--profile <ws-url>` for live services, folder grants, and downloads; downloads accept `--conversation`. |

To inspect skills, use `profile skills` for Profile files, `repository skills` for repository files, or `vm skills` for what the conversation agent can see.

## Drive a conversation and inspect its VM

```sh
ox --profile "$ENDPOINT" conversation list
ox --profile "$ENDPOINT" profile providers
ox --profile "$ENDPOINT" conversation new --json
```

Set `CONVERSATION` to the returned full conversation ID. To choose a model, pass both `--provider <id>` and `--model <id>` when creating the conversation. `--attach <domain,...>` is optional.

```sh
ox --profile "$ENDPOINT" --conversation "$CONVERSATION" conversation send 'Your request' --json
ox --profile "$ENDPOINT" --conversation "$CONVERSATION" conversation inspect --json
ox --profile "$ENDPOINT" --conversation "$CONVERSATION" conversation watch --pending --messages
ox --profile "$ENDPOINT" --conversation "$CONVERSATION" vm inspect
ox --profile "$ENDPOINT" --conversation "$CONVERSATION" vm help ox.fs.read
```

`send` runs the real agent loop and waits by default; pass `--no-wait` to submit and then watch, or `-` to read the message from stdin. Inspect any pending prompt before replying; never infer approval. Use `vm functions` and `vm help <function>` to discover live contracts. Prefer `vm call` over arbitrary `vm eval`; pass sensitive or large arguments through `--args-file -` and keep credentials out of terminal output and arguments.

For conversation hydration, pending prompts, and app configuration, follow [conversation and VM operations](references/conversations.md). To author or repair services through a real Ox conversation, use [develop-services](../develop-services/SKILL.md).

## Inspect resources and invoke services

- [Profiles, repositories, and files](references/profiles-repositories-files.md): read or administer Profiles, validate service sources, download files, and connect repositories through the device’s Files picker.
- [Live services](references/live-services.md): inspect contracts, invoke actions, choose sessions, and use stdio MCP. Ox owns service routing and rendering. An invocation can access authenticated data or change external state; only pass `--approve` when the user has authorized that effect.

## Diagnose a Profile

Start with `ox --profile "$ENDPOINT" profile describe` or `vm inspect`. Read `profile logs --summary --since <ISO-8601>` and narrow with `--level warning` or `--conversation <full-id> conversation logs`. See [diagnostics](references/diagnostics.md) for log interpretation, latency metrics, and connection or service failures. Report the exact target and failure without credentials.

---
name: ox-cli
description: Use the terminal as an Ox Client. Connect to an Ox Host; discover, drive, inspect, or watch conversations; list model providers; read structured logs; inspect or call a VM; administer Profiles; inspect or verify service repositories; and invoke live services.
---

# Ox CLI

`ox` is a terminal Client. Check `ox --help` and the relevant action’s `--help`. Commands stay two levels deep: `ox <namespace> <action>`.

## Choose a Host and resource

Run `ox host list` to discover reachable simulator Hosts and Tailscale peers (`--all` includes unavailable candidates). For live work, select the intended Host with `--host <ws-url>` or `OX_HOST_ENDPOINT`. A `ws://` endpoint without a port uses 9876; `wss://` uses 443. For simulator UI work, follow [simulator setup](../setup/references/simulator.md) and use the reserved device’s explicit UDID.

| Resource | Selector and use |
| --- | --- |
| `host` | `--host` for status (`describe`), providers, and logs. |
| `conversation`, `vm` | `--host` and `--conversation <full-id>` for a conversation and its actual VM. Don’t rely on the active conversation when another is intended. |
| `profile` | `--host` and `--profile <id>` for the Host’s Profiles; `--profile <path>` for offline read-only inspection. Without selectors, `OX_HOST_ENDPOINT` controls Host-backed reads. |
| `repository` | `--repository <path-or-url>` for offline inspection and validation; `list`, `connect`, and `disconnect` manage connections on `--host`. |
| `service`, `files` | `--host` for live services, folder grants, and downloads. Folder administration accepts `--profile`; downloads accept `--conversation`. |

To inspect skills, use `profile skills` for Profile files, `repository skills` for repository files, or `vm skills` for what the conversation agent can see.

## Drive a conversation and inspect its VM

```sh
ox --host "$HOST" conversation list
ox --host "$HOST" host providers
ox --host "$HOST" conversation new --json
```

Set `CONVERSATION` to the returned full conversation ID. To choose a model, pass both `--provider <id>` and `--model <id>` when creating the conversation. `--attach <domain,...>` is optional.

```sh
ox --host "$HOST" --conversation "$CONVERSATION" conversation send 'Your request' --json
ox --host "$HOST" --conversation "$CONVERSATION" conversation inspect --json
ox --host "$HOST" --conversation "$CONVERSATION" conversation watch --pending --messages
ox --host "$HOST" --conversation "$CONVERSATION" vm inspect
ox --host "$HOST" --conversation "$CONVERSATION" vm help ox.fs.read
```

`send` runs the real agent loop and waits by default; pass `--no-wait` to submit and then watch, or `-` to read the message from stdin. Inspect any pending prompt before replying; never infer approval. Use `vm functions` and `vm help <function>` to discover live contracts. Prefer `vm call` over arbitrary `vm eval`; pass sensitive or large arguments through `--args-file -` and keep credentials out of terminal output and arguments.

For conversation hydration, pending prompts, and app configuration, follow [conversation and VM operations](references/conversations.md). To author or repair services through a real Ox conversation, use [develop-services](../develop-services/SKILL.md).

## Inspect resources and invoke services

- [Profiles, repositories, and files](references/profiles-repositories-files.md): read or administer Profiles, validate service sources, download files, and connect repositories through the Host’s Files picker.
- [Live services](references/live-services.md): inspect contracts, invoke actions, choose sessions, and use stdio MCP. The Host owns service routing and rendering. An invocation can access authenticated data or change external state; only pass `--approve` when the user has authorized that effect.

## Diagnose a Host

Start with `ox --host "$HOST" host describe` or `vm inspect`. Read `host logs --summary --since <ISO-8601>` and narrow with `--level warning` or `--conversation <full-id> conversation logs`. See [Host diagnostics](references/diagnostics.md) for log interpretation, latency metrics, and connection or service failures. Report the exact target and failure without credentials.

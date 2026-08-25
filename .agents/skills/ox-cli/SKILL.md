---
name: ox-cli
description: Use the terminal as an Ox Client. Connect to an Ox Host; discover, inspect, or watch chats; read structured logs; run agents; inspect or call a VM; administer Profiles; inspect or verify service repositories; invoke live services; and replay service fixtures.
---

# Ox CLI

`ox` is an Ox Client for the terminal. Consult `ox --help` and the relevant
command help before guessing flags.

The CLI targets architectural resources explicitly:

- `--host <ws-url>` selects an Ox Host for live VM and service commands.
- `--chat <chat-id>` selects a chat-bound VM on that Host.
- `--profile <path>` selects a Profile for direct administration.
- `--repository <path-or-url>` selects service source for offline inspection.

Do not select or infer a web-page runtime. The Host owns service adapters and
decides how live service pages are implemented and managed. Do not use service
or tab session IDs; a live service is addressed by its domain.

## Choose the correct surface

- Use `ox discover` to find iOS Simulator Hosts exposed by a running sim daemon.
- Use `ox chat`, `ox logs`, and `ox agent` for Host-client introspection.
- Use `ox vm` for Host inspection, VM functions, VM-visible skills, and
  execution through the agent's actual capability boundary.
- Use `ox --profile <path>` for direct Profile file operations.
- Use `ox --repository <origin> service` for offline service manifests,
  actions, skills, and replay fixture authoring.
- Use `ox --host <endpoint> service` for live service operations.
- Use `bun run test:chat-projection` for repository projection fixture replay.
- Use `sim` for iOS Simulator interaction.

## Connect to a Host and VM

Target the default DEBUG iOS Simulator Host with `ox vm`. Pass
`--host <ws-url>` or set `OX_HOST_ENDPOINT` for another Host.

```sh
ox chat list
ox chat inspect
ox logs --level warning
ox vm inspect
ox vm functions
ox vm help ox.fs.read
ox vm skills
ox vm skill read <name>
```

Use `--chat <chat-id>` when the active chat is not the intended VM:

```sh
ox --chat <chat-id> chat inspect
ox --chat <chat-id> vm inspect
ox --chat <chat-id> vm call ox.fs.read --args '<json>'
```

Prefer `ox vm call <ox.function> --args <json>` for normal operations. It
preserves the Host's schemas, permissions, approvals, and service attachments.
Use `--args-file -` for sensitive or large arguments. Use `ox vm eval` only
when arbitrary development JavaScript is necessary.

Read a function contract before calling an unfamiliar function:

```sh
ox vm functions --json
ox vm help <ox.function>
```

## Administer a Profile

Discover iCloud Profiles on macOS, then select one by directory:

```sh
ox profiles [--json]
ox --profile <path> memory
ox --profile <path> soul
ox --profile <path> skills [name] [--json]
ox --profile <path> artifacts [filename] [--json]
ox --profile <path> chats [id] [--json]
ox --profile <path> skill create <name> --description <text> (--instructions <text> | --instructions-file <path|->) [--service <domain>]... [--json]
```

Profile inspection is read-only. `skill create` is create-only and refuses to
replace an existing skill. Reading iCloud Drive may require Files & Folders
permission for the terminal or agent host.

## Inspect service repositories

```sh
ox repository inspect <path-or-url>
ox repository validate <path-or-url>
ox repository verify <git-url>
ox repository serve <path-or-url> [--port 8100]
ox --repository <path-or-url> service list [--json]
ox --repository <path-or-url> service inspect -s <domain>
ox --repository <path-or-url> service actions -s <domain> [--json]
ox --repository <path-or-url> service skills -s <domain> [--json]
```

Inspect an action's input schema, authentication requirement, and approval
requirement before invoking it.

## Exercise live services through a Host

```sh
ox [--host <ws-url>] service status [--json] [--timeout 30000]
ox [--host <ws-url>] service invoke <domain>:<action> --args '<json>' [--approve] [--timeout 30000]
ox [--host <ws-url>] service eval <domain> --script '<javascript>' [--timeout 30000]
ox [--host <ws-url>] service reload <domain> [--timeout 30000]
ox [--host <ws-url>] service sync [--timeout 60000]
```

Treat `invoke` as a real action that may read authenticated data or mutate
external state. Supply `--approve` only when the user's request authorizes the
effect. Treat `service eval` as arbitrary code on a Host-managed service page
and keep it narrowly scoped.

Sign-in, human verification, page creation, and page lifecycle happen through
the Host's interface. Do not attempt to choose a page engine, tab, or another
implementation from the Client.

## Replay service fixtures

Prefer the lifecycle-owning repository harness for replay:

```sh
bun run test:services [<domain>:<action>:<case>] --repository <origin> --device <numbered-qa-device>
```

The direct command is intended for the lifecycle-owning harness:

```sh
OX_QA_DEVICE=<device> OX_SERVER_SOURCE=<service-source>/web ox [--host <ws-url>] service test [<domain>:<action>:<case>] --proxy-port <port> [--allow-partial]
```

Replay is fail-closed and must not permit unmatched traffic to reach the
network. Create or revise fixtures through the Host's service-management
workflow, then run the repository harness for verification.

## Connect to Herdr

```sh
ox herdr [--port 8787] [--herdr-session <name>] [--local-only]
```

`--herdr-session` is command-local and refers only to a named Herdr session.
It is unrelated to Host chat selection.

## Diagnose live connection failures

1. Confirm the Host is running.
2. Run `ox vm inspect` or `ox service status` as the smallest probe.
3. Check `--host`, `OX_HOST_ENDPOINT`, then the compatibility
   `OX_DEBUG_ENDPOINT`.
4. Run `ox logs --level warning` before widening to device logs.

Report the exact command, Host endpoint selection method, target resource, and
relevant failure text when blocked. Never print credentials or repository URLs
containing credentials.

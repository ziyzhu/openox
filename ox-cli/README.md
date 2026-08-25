# Ox CLI

```text
■ □ □ ■
■ ■ ■ ■  Ox CLI
□ ■ ■ □
□ ■ ■ □
```

Ox CLI is an Ox Client for the terminal. It can discover and connect to an Ox
Host, inspect chats, logs, agents, and VMs, administer Profile
content directly, inspect service repositories, and ask a Host to exercise
live services.

The CLI never selects a web-page runtime. The Host owns service adapters and
decides how each service page is implemented and managed.

## Install

Ox CLI requires [Bun](https://bun.sh/) 1.3 or newer.

```sh
bun install --global @openox/cli
ox --version
```

You can also install through npm after installing Bun:

```sh
npm install --global @openox/cli
```

Run it without a global installation with `bunx @openox/cli --help`.

### Install from source

```sh
git clone https://github.com/ziyzhu/openox.git
cd openox
bun install
cd ox-cli
bun run build
bun link
ox --help
```

## Targeting model

The global selectors each identify one architectural resource:

```text
ox
├── --host <ws-url>              Ox Host control endpoint
├── --chat <chat-id>             Chat-bound VM on that Host
├── --profile <profile-path>     Profile directory for direct administration
└── --repository <path-or-url>   Service repository for offline inspection
```

- `--host` applies to live chat, log, agent, VM, and service commands. It defaults to
  `OX_HOST_ENDPOINT`, then the compatibility `OX_DEBUG_ENDPOINT`, then
  `ws://127.0.0.1:9876`.
- `--chat` applies to `ox chat`, `ox agent`, and `ox vm`. Obtain IDs with
  `ox chat list`.
- `--profile` bypasses a Host and operates directly on a Profile directory
  containing `profile.json`.
- `--repository` selects source data for repository and offline service
  commands. It does not choose the Host's live service implementation.

Global selectors are position-independent.

## Connect to an Ox Host

A running DEBUG iOS Simulator app exposes the reference Host on a loopback
WebSocket:

```sh
ox discover
ox chat list
ox chat inspect
ox vm inspect
ox vm functions
ox vm help ox.fs.read
ox vm skills
ox vm skill read system:manage-skills
```

Select a specific chat-bound VM when the active chat is not the intended
target:

```sh
ox --chat <chat-id> chat inspect
ox --chat <chat-id> vm inspect
ox --chat <chat-id> vm call ox.fs.read \
  --args '{"path":"skills/system:manage-skills/SKILL.md","purpose":"Read skill"}'
```

`vm call` invokes a catalogued `ox.*` function with structured JSON
arguments and preserves the Host's schemas, permissions, approvals, and
service attachments. Read arguments from stdin when they should not appear in
shell history:

```sh
ox vm call ox.fs.list --args-file - < vm-args.json
```

`vm eval` runs arbitrary JavaScript and is intended only for development:

```sh
ox vm eval --script 'return await ox.app.inspect({ purpose: "Inspect Host" });'
```

## Inspect a running Host

The CLI replaces the former development website with scriptable commands:

```sh
ox chat list
ox --chat <chat-id> chat inspect --messages --blocks
ox --chat <chat-id> chat watch --json
ox logs --level warning
ox logs --follow
ox agent list
ox --chat <chat-id> agent replay --client <provider> --model <model>
ox --chat <chat-id> agent run --prompt "Diagnose this failure"
```

One-shot JSON commands emit ordinary JSON. Streaming `chat watch --json` and
`logs --follow --json` emit one JSON object per line. Watch commands use
request-based snapshots, tolerate Host restarts, and retry until interrupted.
Repository history remains available through ordinary `git log` and `git show`;
the CLI does not duplicate generic Git visualization.

## Use live services through a Host

Live service commands address the selected Host. The domain identifies the
service; there is no tab ID, service session ID, or client-selected runtime.

```sh
ox service status
ox service status --json
ox service invoke <domain>:<action> --args '<json>'
ox service eval <domain> --script 'return document.title;'
ox service reload <domain>
ox service sync
```

Target another Host with `--host <ws-url>`:

```sh
ox --host ws://127.0.0.1:9101 service status
```

Sign-in, approvals, human verification, page creation, and page lifecycle are
Host responsibilities. An approval-gated action stops unless invocation
includes `--approve`; only pass it when the requested external effect is
intended.

## Inspect a Profile directly

On macOS, discover Profiles in the Ox iCloud Drive container:

```sh
ox profiles
ox profiles --json
```

Then select one explicitly:

```sh
ox --profile "/path/to/My Profile" memory
ox --profile "/path/to/My Profile" soul
ox --profile "/path/to/My Profile" skills
ox --profile "/path/to/My Profile" skills <name>
ox --profile "/path/to/My Profile" skill create weekly-review \
  --description "Prepare a concise weekly review" \
  --service mail.google.com \
  --instructions-file ./weekly-review.md
ox --profile "/path/to/My Profile" artifacts
ox --profile "/path/to/My Profile" artifacts <filename>
ox --profile "/path/to/My Profile" chats
ox --profile "/path/to/My Profile" chats <id> --json
```

Inspection commands are read-only. `skill create` writes one canonical
`skills/<name>/SKILL.md` and refuses to replace an existing skill. Repeat
`--service` to bind multiple services. Use `--instructions-file -` to read
instructions from stdin.

`ox profiles` is macOS-only. `--profile` can point to a Profile directory
on any supported platform. Artifact JSON listings report cloud-only iCloud
placeholders without downloading them.

## Inspect service repositories

Repository inspection is offline and does not contact a Host:

```sh
ox repository inspect /path/to/repository
ox repository validate /path/to/repository
ox repository verify https://example.com/services.git
ox repository serve /path/to/repository --port 8101
ox --repository /path/to/repository service list
ox --repository /path/to/repository service inspect -s mail.google.com
ox --repository /path/to/repository service actions -s mail.google.com --json
ox --repository /path/to/repository service skills -s mail.google.com --json
```

Repository origins may be local paths, loopback Git URLs, or HTTPS Git URLs.
Private HTTPS repositories are cloned with the developer's Git credentials
before being served; credentials are never embedded in the URL.

## Test services

The repository harness owns the complete iOS replay lifecycle:

```sh
bun run test:services --repository /path/to/service-repository --device ox-qa-1
bun run test:services <domain>:<action>:<case> \
  --repository /path/to/service-repository \
  --device ox-qa-1
```

Replay runs production action code through the iOS Host while mitmproxy serves
committed responses. Requests absent from the HAR are terminated locally. The
CLI only replays reviewed fixtures; fixture creation happens through the Ox
Host's service-management workflow.

## Connect Ox to Herdr

`ox herdr` starts an MCP bridge to local Herdr agents and exposes it privately
through a foreground Tailscale Serve process:

```sh
ox herdr
ox herdr --herdr-session <name>
ox herdr --port 8788 --local-only
```

`--herdr-session` is local to this command and selects a named Herdr session.
The bridge refuses to replace an existing Tailscale Serve route and removes its
own route when the command exits.

## Command reference

```text
ox profiles [--json]
ox --profile <path> memory
ox --profile <path> soul
ox --profile <path> skills [name] [--json]
ox --profile <path> artifacts [filename] [--json]
ox --profile <path> chats [id] [--json]
ox --profile <path> skill create <name> --description <text> (--instructions <text> | --instructions-file <path|->) [--service <domain>]... [--json]

ox herdr [--port 8787] [--herdr-session <name>] [--local-only]

ox discover [--json] [--timeout 3000]
ox [--host <ws-url>] chat list [--json] [--timeout 30000]
ox [--host <ws-url>] [--chat <chat-id>] chat inspect [--system|--tools|--messages|--blocks] [--full] [--json] [--timeout 30000]
ox [--host <ws-url>] [--chat <chat-id>] chat watch [--system|--tools|--messages|--blocks] [--full] [--json] [--timeout 30000] [--interval 1000]
ox [--host <ws-url>] logs [--level debug|info|warning|error] [--grep <substring>] [--tail <count>] [--follow] [--json] [--timeout 30000] [--interval 1000]
ox [--host <ws-url>] agent list [--json] [--timeout 30000]
ox [--host <ws-url>] [--chat <chat-id>] agent run --prompt <text> [--client <id>] [--model <id>] [--json] [--timeout 120000]
ox [--host <ws-url>] [--chat <chat-id>] agent replay [--client <id>] [--model <id>] [--json] [--timeout 120000]

ox [--host <ws-url>] [--chat <chat-id>] vm inspect [--json] [--timeout 30000]
ox [--host <ws-url>] vm functions [--json] [--timeout 30000]
ox [--host <ws-url>] vm help <ox.function> [--json] [--timeout 30000]
ox [--host <ws-url>] [--chat <chat-id>] vm call <ox.function> [--args '{}'] [--args-file <path|->] [--json] [--timeout 60000]
ox [--host <ws-url>] [--chat <chat-id>] vm eval (--script '<javascript>' | --script-file <path|->) [--json] [--timeout 60000]
ox [--host <ws-url>] [--chat <chat-id>] vm skills [--json] [--timeout 60000]
ox [--host <ws-url>] [--chat <chat-id>] vm skill read <name> [--json] [--timeout 60000]

ox repository inspect <path-or-url>
ox repository validate <path-or-url>
ox repository verify <git-url>
ox repository serve <path-or-url> [--port 8100]
ox --repository <path-or-url> service list [--json]
ox --repository <path-or-url> service inspect -s <domain>
ox --repository <path-or-url> service actions -s <domain> [--json]
ox --repository <path-or-url> service skills -s <domain> [--json]
ox [--host <ws-url>] service test [<domain>[:<action>[:<case>]]] --source <directory> --proxy-port <port> [--timeout 30000] [--allow-partial]
ox [--host <ws-url>] service status [--json] [--timeout 30000]
ox [--host <ws-url>] service invoke <domain>:<action> [--args '{}'] [--approve] [--timeout 30000]
ox [--host <ws-url>] service eval <domain> --script '<javascript>' [--timeout 30000]
ox [--host <ws-url>] service reload <domain> [--timeout 30000]
ox [--host <ws-url>] service sync [--timeout 60000]
```

Use `ox --help`, `ox chat --help`, `ox vm --help`, or `ox service --help` for the installed
CLI's current syntax.

## Troubleshooting

If a Host command cannot connect, confirm the Host is running and that
`--host`, `OX_HOST_ENDPOINT`, or the compatibility `OX_DEBUG_ENDPOINT`
matches its control endpoint.

If an action requires sign-in or human verification, complete it through the
Host's own interface. If a changed service remains cached, refresh the Host's
repository source and run `ox service sync`.

## Development

From the repository root:

```sh
bun run typecheck
cd ox-cli
bun run build
bun run package:check
```

`package:check` builds the publishable bundle, verifies the tarball, installs
it into a temporary global prefix, and exercises the installed CLI.

## Release

The version in `package.json` is the source of truth. Update it on `main`,
run the package check, then create a matching `ox-cli-v<version>` tag.

The first npm release must be published interactively:

```sh
cd ox-cli
bun package-check.ts --output /tmp/ox-cli-release
npm publish /tmp/ox-cli-release/openox-cli-0.1.0.tgz --access public
```

After npm Trusted Publishing is configured, push the matching tag:

```sh
git tag ox-cli-v0.1.0
git push origin ox-cli-v0.1.0
```

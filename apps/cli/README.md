# Ox CLI

```text
■ □ □ ■
■ ■ ■ ■  Ox CLI
□ ■ ■ □
□ ■ ■ □
```

Ox CLI is an Ox Client for the terminal. Commands are grouped by the resource
they act on: a Profile on disk, a service repository, an Ox Host, a chat on that
Host, or the chat's VM.

`ox serve` exposes selected local Herdr actions to Ox as MCP tools.

The CLI never selects a web-page runtime. The Host owns service adapters and
decides how each service page is implemented and managed. The current wire
protocol is JSON-RPC 2.0 over WebSocket; `ox host describe` reports the Host's
identity and supported methods. The [shared RPC contract](../../packages/protocol/README.md)
defines parameter/result schemas and reusable Host conformance fixtures.

## Install

Install the standalone CLI on macOS or Linux without installing Bun or Node.js:

```sh
curl -fsSL https://raw.githubusercontent.com/ziyzhu/openox/main/apps/cli/install.sh | sh
ox --version
ox --help
```

The installer downloads an `ox-cli-v<version>` GitHub Release, verifies its
SHA-256 checksum and executable version, and installs `ox` into `~/.local/bin`.
It supports Apple Silicon and Intel macOS, and ARM64 and x64 Linux with glibc.
Standalone installation becomes available when the first CLI GitHub Release
is published.

Run the same installer command to update. If the install directory is missing
from your PATH, follow the printed shell instructions. If another `ox` is
already on PATH, remove that installation first or select its directory with
`OX_INSTALL_DIR`. Package-manager symlinks must be uninstalled with their
original package manager before switching to standalone installation.

To select a version or installation directory:

```sh
curl -fsSL https://raw.githubusercontent.com/ziyzhu/openox/main/apps/cli/install.sh \
  | OX_CLI_VERSION=0.1.0 OX_INSTALL_DIR="$HOME/.local/bin" sh
```

To uninstall a standalone installation, remove the installed `ox` executable.

### Package managers

Package-manager installations require [Bun](https://bun.sh/) 1.3 or newer:

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
cd apps/cli
bun run build
bun link
ox --help
ox host discover --help
```

Run `bun link` inside `apps/cli`, not `bun link @openox/cli` at the workspace
root; the latter introduces a dependency loop with the existing workspace.
Rebuild after source changes or switching worktrees. If `ox --help` still lists
old top-level `discover`, `logs`, or `service` commands, check `command -v ox`
and resolve the stale installation or PATH ordering. See
[onboarding skill](../../.agents/skills/onboarding/SKILL.md)
for agent and simulator setup.

## Targeting model

Each command group acts on one resource, selected by its global flag:

```text
ox
├── profile      --profile <path>             Profile directory on disk
├── repository   --repository <path-or-url>   Service repository
├── host         --host <ws-url>              Ox Host control endpoint
├── chat         --host, --chat <chat-id>     Chat on that Host
├── vm           --host, --chat <chat-id>     The chat's VM
└── serve                                     Local Herdr MCP bridge
```

- `--host` defaults to `OX_HOST_ENDPOINT`, then the compatibility
  `OX_DEBUG_ENDPOINT`, then `ws://127.0.0.1:9876`. It applies to `ox host`,
  `ox chat`, `ox vm`, and `ox repository test`.
- `--chat` selects a chat for `ox chat` and `ox vm`; without it, the Host's
  active chat is used. Obtain IDs with `ox chat list`.
- `--profile` applies only to `ox profile` and bypasses any Host.
- `--repository` applies only to `ox repository`. It never chooses the Host's
  live service implementation.
- `ox serve` has no Host selector; it runs beside the local Herdr session.

Global flags are position-independent. Skills appear in three groups because
they come from three sources: `ox profile skills` reads a Profile's files,
`ox repository skills` reads a repository's files, and `ox vm skills` shows what
the agent in a chat actually sees.

## Expose Herdr actions to Ox

`ox serve` starts a foreground MCP bridge on loopback and publishes it through
Tailscale Serve. It exposes `agent_list`, `agent_get`, `agent_read`,
`agent_prompt`, and `agent_wait` by default. Repeat `--action` to replace that
set with an explicit allowlist; `ox serve --help` lists every available action.

```sh
ox serve
ox serve --action agent_list --action agent_read
ox serve --herdr-session work --local-only
```

`--local-only` prints a loopback MCP URL instead of starting Tailscale Serve.
The bridge refuses to replace an existing Tailscale Serve route and stops its
own route when the command exits. Add the printed MCP endpoint as a service in
Ox to make the selected tools available to a chat.

## Inspect and operate a Host

The iOS Host uses the same JSON-RPC WebSocket API in Debug and Release builds,
on Simulator and device. Enable **Settings → Host → Allow connections** first;
the saved choice defaults off when absent. After Host preparation it listens
while Ox is active, restricted to the device's configured **Tailscale VPN
interface and local addresses**. Turning the toggle off immediately closes
listeners and connected Clients. The inline Host section has only the toggle
and foreground/Tailscale guidance. Find the phone's tailnet address or hostname
in Tailscale. Connect Tailscale on both devices, keep Ox open, and pass
its tailnet hostname or address explicitly:

```sh
ox --host ws://<phone-name>.<tailnet>.ts.net:9876 host describe
```

Port 9876 is the default. A `ws://` launch endpoint with an explicit port
(`OX_HOST_ENDPOINT`, or compatibility `OX_DEBUG_ENDPOINT`) overrides only the
port; it cannot select a LAN or loopback interface. Tailnet grants authorize the
intended Clients; no separate Ox pairing credentials are required. There is no
LAN, public-internet, loopback, or USB-forwarding fallback. Missing or ambiguous
VPN ingress disables networking. Browser-origin handshakes are rejected.
Simulator QA also requires the same VPN ingress; old loopback launch URLs do
not create a bypass. The CLI's legacy loopback default is not a reachable iOS
Host under this policy. Ingress discovery trusts the device's configured VPN;
local address ranges are not remote peer credentials. Authentication and access
grants remain Tailscale's responsibility.

```sh
ox host discover
ox host describe
ox host logs --level warning
ox host logs --follow
ox host providers
```

One-shot JSON commands emit ordinary JSON. Streaming `chat watch --json` and
`host logs --follow --json` emit one JSON object per line. Watch commands use
request-based snapshots, tolerate Host restarts, and retry until interrupted.
Mutations are never automatically retried: a connection failure before sending
reports Host unavailability; a timeout or disconnect after sending reports an
unknown outcome. Reconnect and inspect state before resubmitting work.
Known method parameters are schema-validated before submission; successful results
are validated against the same shared contract. Invalid mutation results do not
cause resubmission. `host.describe` advertises supported RPC contract versions
under `protocols.rpc`; older Hosts without that field remain supported.
Connections are scoped to the Profile present when they connect; reconnect after
a Profile switch. Service invocation respects the Host's action policies;
`--approve` cannot override a Block policy.

## Drive a chat

`chat send` runs the same turn as typing in the app: the chat's current system
prompt, per-turn context, tools, attached services, and compaction all apply,
and the turn is saved to the chat. `chat new` makes the new chat active, so
subsequent commands target it without `--chat`.

```sh
ox chat new --temporary --provider <provider> --model <model> --attach <domain>
ox chat send "Summarize my unread messages"
echo "Long prompt" | ox chat send -
ox --chat <chat-id> chat send --no-wait "Keep going"
ox --chat <chat-id> chat stop
ox chat list
ox --chat <chat-id> chat inspect --messages --blocks
ox --chat <chat-id> chat watch --json
```

`chat send` waits for the turn and prints the response. It exits 1 when the
turn fails, is cancelled, or pauses for a user response such as an approval;
answer the prompt in the app or stop the turn. Use `sim` instead when the UI
itself is under test.

## Use a chat's VM

```sh
ox vm inspect
ox vm functions
ox vm help ox.fs.read
ox vm skills
ox vm skills manage-skills
ox --chat <chat-id> vm call ox.fs.read \
  --args '{"path":"skills/manage-skills/SKILL.md","purpose":"Read skill"}'
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
ox vm eval --script 'return await ox.app.info({ purpose: "Read app identity" });'
```

## Use live services through a Host

Live service commands address the selected Host. The domain identifies the
service; there is no tab ID, service session ID, or client-selected runtime.

```sh
ox host services
ox host services --json
ox host service invoke <domain>:<action> --args '<json>'
ox host service eval <domain> --script 'return document.title;'
ox host service reload <domain>
ox host service sync
ox --host ws://127.0.0.1:9101 host services
```

Sign-in, approvals, human verification, page creation, and page lifecycle are
Host responsibilities. An approval-gated action stops unless invocation
includes `--approve`; only pass it when the requested external effect is
intended.

## Inspect a Profile directly

On macOS, discover Profiles in the Ox iCloud Drive container, then select one:

```sh
ox profile list
ox --profile "/path/to/My Profile" profile memory
ox --profile "/path/to/My Profile" profile soul
ox --profile "/path/to/My Profile" profile skills [name]
ox --profile "/path/to/My Profile" profile artifacts [filename]
ox --profile "/path/to/My Profile" profile chats [id] --json
```

Profile commands are read-only. `ox profile list` is macOS-only; `--profile`
can point to a Profile directory on any supported platform. Artifact JSON
listings report cloud-only iCloud placeholders without downloading them.

## Inspect repositories

Repository commands are offline except `test`, which replays through a Host:

```sh
ox --repository /path/to/repository repository inspect
ox --repository /path/to/repository repository validate
ox --repository https://example.com/services.git repository verify
ox --repository /path/to/repository repository serve --port 8101
ox --repository /path/to/repository repository services
ox --repository /path/to/repository repository services mail.google.com
ox --repository /path/to/repository repository actions mail.google.com --json
ox --repository /path/to/repository repository skills --json
```

`validate` and `serve` check `repository.json` and every web and API service:
each `service.json` against the manifest rules the Host accepts, and each
`actions.js` by running its installer with only `action` (plus `request` for API
services) and matching the registered actions to the manifest. Every invalid
service is reported.

Repository origins may be local paths, loopback Git URLs, or HTTPS Git URLs.
Private HTTPS repositories are cloned with the developer's Git credentials
before being served; credentials are never embedded in the URL.

## Test services

The repository harness owns the complete iOS replay lifecycle:

```sh
bun run test:services --device ox-1
bun run test:services <domain>:<action>:<case> --device ox-1
bun run test:services <domain>:<action>:<case> \
  --repository /path/to/repository --device ox-1
```

Replay uses bundled services by default. Pass `--repository` to exercise loading
a local repository through a simulator-specific loopback server. Production action
code runs through the iOS Host while mitmproxy serves committed responses. Requests absent from the HAR are terminated locally. The
CLI only replays reviewed fixtures; fixture creation happens through the Ox
Host's service-management workflow.

## Command reference

```text
ox profile list [--json]
ox --profile <path> profile memory
ox --profile <path> profile soul
ox --profile <path> profile skills [name] [--json]
ox --profile <path> profile artifacts [filename] [--json]
ox --profile <path> profile chats [id] [--json]

ox --repository <path-or-url> repository inspect
ox --repository <path-or-url> repository validate
ox --repository <git-url> repository verify
ox --repository <path-or-url> repository serve [--port 8100]
ox --repository <path-or-url> repository services [domain] [--json]
ox --repository <path-or-url> repository actions <domain> [--json]
ox --repository <path-or-url> repository skills [name] [--json]
ox [--host <ws-url>] --repository <path-or-url> repository test [<domain>[:<action>[:<case>]]] --proxy-port <port> [--timeout 30000] [--allow-partial]

ox host discover [--json] [--timeout 3000]
ox [--host <ws-url>] host describe [--json] [--timeout 30000]
ox [--host <ws-url>] host logs [--level debug|info|warning|error] [--grep <substring>] [--tail <count>] [--follow] [--json] [--timeout 30000] [--interval 1000]
ox [--host <ws-url>] host providers [--json] [--timeout 30000]
ox [--host <ws-url>] host services [--json] [--timeout 30000]
ox [--host <ws-url>] host service invoke <domain>:<action> [--args '{}'] [--approve] [--timeout 30000]
ox [--host <ws-url>] host service eval <domain> --script '<javascript>' [--timeout 30000]
ox [--host <ws-url>] host service reload <domain> [--timeout 30000]
ox [--host <ws-url>] host service sync [--timeout 60000]

ox [--host <ws-url>] chat list [--json] [--timeout 30000]
ox [--host <ws-url>] chat new [--temporary] [--provider <id> --model <id>] [--attach <domain,...>] [--json] [--timeout 30000]
ox [--host <ws-url>] [--chat <chat-id>] chat send <text | -> [--no-wait] [--json] [--timeout 600000]
ox [--host <ws-url>] [--chat <chat-id>] chat stop [--json] [--timeout 30000]
ox [--host <ws-url>] [--chat <chat-id>] chat inspect [--system|--tools|--messages|--blocks] [--full] [--json] [--timeout 30000]
ox [--host <ws-url>] [--chat <chat-id>] chat watch [--system|--tools|--messages|--blocks] [--full] [--json] [--timeout 30000] [--interval 1000]

ox [--host <ws-url>] [--chat <chat-id>] vm inspect [--json] [--timeout 30000]
ox [--host <ws-url>] vm functions [--json] [--timeout 30000]
ox [--host <ws-url>] vm help <ox.function> [--json] [--timeout 30000]
ox [--host <ws-url>] [--chat <chat-id>] vm call <ox.function> [--args '{}'] [--args-file <path|->] [--json] [--timeout 60000]
ox [--host <ws-url>] [--chat <chat-id>] vm eval (--script '<javascript>' | --script-file <path|->) [--json] [--timeout 60000]
ox [--host <ws-url>] [--chat <chat-id>] vm skills [name] [--json] [--timeout 60000]
```

Use `ox --help` or `ox <group> --help` for the installed CLI's current syntax.

## Troubleshooting

If a Host command cannot connect, confirm the Host is running and that
`--host`, `OX_HOST_ENDPOINT`, or the compatibility `OX_DEBUG_ENDPOINT`
matches its control endpoint.

If an action requires sign-in or human verification, complete it through the
Host's own interface. If a changed service remains cached, refresh the Host's
repository source and run `ox host service sync`.

## Development

From the repository root:

```sh
bun run typecheck
cd apps/cli
bun run build
bun run package:check
bun run standalone:check
bun run build:standalone --platform linux-x64 --out /tmp/ox-cli-artifacts
```

`package:check` builds the publishable bundle, verifies the tarball, installs
it into a temporary global prefix, and exercises the installed CLI.

`standalone:check` builds for the current platform, downloads and installs the
archive through a local fixture server, and exercises the installed executable
without Bun or Node.js on PATH. It checks repository inspection and validation,
Host discovery, a WebSocket Host request, and isolation from working-directory
`.env` and `bunfig.toml` files. Pass `--out <directory>` to retain release
artifacts; otherwise they are removed with the temporary test files.

## Release

The version in `package.json` is the source of truth. Update it on `main`,
run both package and standalone checks, wait for CI, then create a matching
`ox-cli-v<version>` tag. The release workflow requires all four standalone
platforms to pass installation and runtime checks before publishing npm.
After npm publication succeeds, it publishes the standalone archives,
`SHA256SUMS`, and `install.sh` as a CLI-specific GitHub Release. The installer
selects stable CLI tags independently of SDK and service releases.

The first npm release must be published interactively:

```sh
cd apps/cli
bun package-check.ts --output /tmp/ox-cli-release
npm publish /tmp/ox-cli-release/openox-cli-0.1.0.tgz --access public
```

After npm Trusted Publishing is configured, push the matching tag:

```sh
git tag ox-cli-v0.1.0
git push origin ox-cli-v0.1.0
```

## Host compatibility

All live Host commands use JSON-RPC 2.0. Update the Host and CLI together;
older wire formats are not supported. `ox host describe --json` reports Host
identity, supported protocol versions, and methods.

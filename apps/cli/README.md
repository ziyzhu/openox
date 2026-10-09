# Ox CLI

Ox CLI is an Ox Client for the terminal on macOS and Linux. It connects to an
Ox Host for live operations and can inspect Profiles and repositories offline.
The Host owns service runtimes, permissions, approvals, and credentials.

## Install

Install the standalone CLI without Bun or Node.js:

```sh
curl -fsSL https://raw.githubusercontent.com/ziyzhu/openox/main/apps/cli/install.sh | sh
ox --version
ox --help
```

The installer requires a published `ox-cli-v<version>` GitHub Release. It verifies
the SHA-256 checksum and executable version, then installs into `~/.local/bin`.
Supported platforms are Apple Silicon and Intel macOS, and ARM64 and x64 Linux
with glibc. Run the same command to update; remove the executable to uninstall.

Select a version or directory with `OX_CLI_VERSION` and `OX_INSTALL_DIR`:

```sh
curl -fsSL https://raw.githubusercontent.com/ziyzhu/openox/main/apps/cli/install.sh \
  | OX_CLI_VERSION=0.1.0 OX_INSTALL_DIR="$HOME/.local/bin" sh
```

If another `ox` is on PATH, uninstall it through its original package manager
before switching to standalone installation, or select a different directory.

Package-manager installation requires [Bun](https://bun.sh/) 1.3 or newer:

```sh
bun install --global @openox/cli
```

With Bun installed, `npm install --global @openox/cli` also works. Use
`bunx @openox/cli --help` without a global installation.

For source installation and simulator setup, follow the
[onboarding skill](../../.agents/skills/onboarding/SKILL.md).

## Connect to a Host

On iOS, enable **Settings → Host → Allow connections**, connect both devices to
Tailscale, and keep Ox in the foreground. Pass the phone's tailnet hostname or
address explicitly:

```sh
ox --host ws://<phone-name>.<tailnet>.ts.net:9876 host describe
```

All builds use the same JSON-RPC 2.0 WebSocket API. Physical-device and Release
Hosts listen only on their configured Tailscale VPN interface and addresses;
missing or ambiguous VPN ingress disables networking. Tailscale grants control
access. There is no separate Ox pairing credential, LAN, public-internet, or
USB-forwarding fallback. Browser-origin handshakes are rejected. Turning off
Allow connections closes existing Clients.

Debug Simulator builds can explicitly opt into local development access:

```sh
sim --device ox-3 run <bundle-id> --project apps/ios/Ox.xcodeproj --scheme ios \
  --env OX_DEBUG_ENDPOINT=ws://127.0.0.1:9103 --env OX_HOST_LOOPBACK=1
ox --host ws://127.0.0.1:9103 host describe
```

Allow connections must still be enabled. This launch-only mode binds exclusively
to `127.0.0.1`, trusts local processes, and requires no Tailscale. The loopback code
is compiled out on physical devices and Release builds. Relaunch without the flag
to restore Tailscale-only access. Use a dedicated QA simulator, not personal state.

Port 9876 is the default. `OX_HOST_ENDPOINT`/`OX_DEBUG_ENDPOINT` can override the
port; only `OX_HOST_LOOPBACK=1` selects Debug Simulator loopback.

```sh
ox host list
ox host describe
ox host providers
ox host logs --level warning
```

`host list` probes simulator-daemon candidates and online iOS Tailscale peers;
`--all` includes unavailable candidates. Physical-device discovery uses port
9876; pass `--host` for another port.

## Select a resource

| Group | Target |
| --- | --- |
| `ox profile` | `--profile <path>`: a Profile on disk, read-only |
| `ox repository` | `--repository <path-or-url>`: repository contents, without a Host |
| `ox host` | `--host <ws-url>`: a running Host |
| `ox chat` | `--host`, `--chat <id>`: a chat on that Host |
| `ox vm` | `--host`, `--chat <id>`: that chat's VM |

Global flags are position-independent. Without `--chat`, live commands use the
Host's active chat. `--host` defaults to `OX_HOST_ENDPOINT`, then compatibility
`OX_DEBUG_ENDPOINT`, then `ws://127.0.0.1:9876`. That legacy loopback default
works only with an explicitly opted-in Debug Simulator Host on that port.

Connections are scoped to the Profile present when they connect; reconnect
after switching Profiles. `--repository` never selects a Host's live runtime.
Use `ox --help` and `ox <group> --help` for current commands and options.

## Drive a chat

```sh
ox chat new --temporary --provider <provider> --model <model> --attach <domain>
ox chat send "Summarize my unread messages"
ox chat list
ox --chat <chat-id> chat inspect --messages --pending --json
ox --chat <chat-id> chat watch --json
ox --chat <chat-id> chat stop
```

`chat new` selects the new chat. `chat send` uses the app's agent loop and saves
the turn. It waits by default and exits 1 if the turn fails, is cancelled, or
pauses for a user response. Inspect the pending prompt, then answer its exact ID:

```sh
ox --chat <chat-id> chat respond "Approve" --prompt <prompt-id>
```

Use an option label returned by the prompt; custom answers require
`allowsCustomAnswer`. `chat respond` acknowledges without waiting for the resumed
turn, so follow with `chat watch`. Credential entry and other app-only
interactions still require Ox. Use `chat open` to select a saved chat; opening
another chat discards an outgoing temporary chat, just as in the app.

## Use capabilities

```sh
ox vm functions
ox vm help ox.fs.read
ox vm skills
ox vm call ox.fs.read --args '{"path":"skills/manage-skills/SKILL.md","purpose":"Activate the System authoring skill"}'
ox host services
ox host service invoke <domain>:<action> --args-file - < action-args.json
ox host service sync
```

VM calls preserve the Host's permissions, approvals, and service attachments.
Live service actions identify a service by domain, not a tab or runtime. Pass
`--approve` only when an approval-gated external effect is intended; it cannot
override a Block policy. Use `--args-file -` to keep sensitive arguments out of
shell history. Arbitrary evaluation commands are intended for development.

## Read diagnostics

```sh
ox host logs --all --level warning --grep timeout --json
ox host logs --tail 5000 --category Session
ox host logs --follow --json
```

On iOS, logs are retained on-device across app runs with size-based retention.
Ordinary reads return the latest 2,000 matches by default; `--all` walks older
pages. `--page --json` returns `{ logs, nextCursor, hasMore }`; use `--cursor` to
continue with unchanged filters. Expired cursors require a fresh read.

One-shot JSON commands emit ordinary JSON; watch/follow commands emit one JSON
object per line. Watch commands poll snapshots and tolerate Host restarts.
Mutations are never automatically retried. A timeout or disconnect after sending
means the outcome is unknown: reconnect and inspect state before resubmitting.
Known parameters and successful results are checked against the
[shared protocol](../../packages/protocol/README.md); invalid results do not
justify retrying a mutation.

## Inspect offline data

```sh
ox profile list
ox --profile "/path/to/My Profile" profile memory
ox --profile "/path/to/My Profile" profile chats --json
ox --repository examples/repository repository validate
ox --repository /path/to/repository repository serve --port 8101
ox --repository https://example.com/services.git repository verify
```

`profile list` discovers iCloud Profiles on macOS; explicit Profile paths work
on any supported platform. Repository validation checks manifests and action
installer registrations. Private HTTPS repositories use local Git credentials;
never embed credentials in URLs.

## Troubleshooting

For connection failures, check foreground Host availability, Allow connections,
the selected endpoint, and Tailscale or the explicit Debug Simulator loopback opt-in. Complete sign-in and human verification
through the Host's UI. If a changed service stays cached, refresh its repository
source and run `ox host service sync`.

For a stale source installation, check `command -v ox` and rebuild after source
changes or switching worktrees. Use the [test skill](../../.agents/skills/test/SKILL.md)
for verification and the [release skill](../../.agents/skills/release/SKILL.md)
for package publication.

To connect Ox to Pi through MCP, run [pi-mcp](https://github.com/ziyzhu/pi-mcp)
separately and add its printed Streamable HTTP URL in Ox's remote MCP settings.
Setup instructions live in that repository.

# Ox CLI

```text
■ □ □ ■
■ ■ ■ ■  Ox CLI
□ ■ ■ □
□ ■ ■ □
```

Ox CLI inspects and manages Profile content and exercises Ox services from a terminal. It can read a Profile's memory, soul, skills, artifacts, and chats, create user skills, inspect service definitions on disk, and run service actions through either the Ox iOS app or a dedicated headed Chrome profile.

## Connect Ox to Herdr

Start an MCP bridge to the default local Herdr session and expose it privately
to your tailnet through a foreground Tailscale Serve process:

```sh
ox herdr
```

Use `--session <name>` for a named Herdr session and `--port <port>` to replace
the default loopback port `8787`. `ox herdr` prints the resulting tailnet-only
HTTPS MCP endpoint for Ox on a physical iPhone. It refuses to replace an
existing Tailscale Serve route and removes its own foreground route when the
command exits. Use `--local-only` to skip Tailscale and expose only
`http://127.0.0.1:<port>/mcp`.

The bridge exposes bounded status and agent supervision, including structured
agent details, detection diagnostics, prompting, output reads, and state waits.
It can inspect workspaces, tabs, worktrees, panes, and pane processes, and wait
for a literal substring in bounded pane output. It can also create and rename
workspaces and tabs, create or open worktrees, start and rename supported
agents, focus agents/workspaces/tabs for handoff, and show Mac notifications.
Agents can save artifacts under `artifacts/` in their working directory and
report workspace-relative paths. The bridge can list recent supported files
with `agent_artifact_list` and return one with `agent_artifact_get` as standard
MCP image or embedded resource content. Artifact reads stay inside the resolved
agent artifact directory, reject symlink escapes, and enforce a transfer-size
limit compatible with Ox's MCP client.
Workspace and tab closure and non-forced worktree removal require explicit
confirmation. It does not expose arbitrary shell execution, environment or
agent-argument injection, regular-expression matching, raw terminal
keystrokes, pane closure, forced worktree removal, direct pane layout mutation,
or Herdr maintenance. Ox requests approval before invoking every remote MCP
tool.

## Install

Ox CLI requires [Bun](https://bun.sh/) 1.3 or newer. The Chrome runtime also requires Google Chrome Stable.

```sh
bun install --global @openox/cli
ox --version
```

You can also install through npm after installing Bun:

```sh
npm install --global @openox/cli
```

Run a command without keeping a global installation with `bunx`:

```sh
bunx @openox/cli --help
```

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

Select service repositories explicitly with `--repository <path-or-url>`.

## Inspect a Profile

On macOS, list the Profiles in the Ox iCloud Drive container:

```sh
ox profiles
ox profiles --json
```

Then point `--root` at one of the returned directories:

```sh
ox --root "/path/to/My Profile" memory
ox --root "/path/to/My Profile" soul
ox --root "/path/to/My Profile" skills
ox --root "/path/to/My Profile" skills <name>
ox --root "/path/to/My Profile" skill create weekly-review \
  --description "Prepare a concise weekly review" \
  --service mail.google.com \
  --instructions-file ./weekly-review.md
ox --root "/path/to/My Profile" artifacts
ox --root "/path/to/My Profile" artifacts <filename>
ox --root "/path/to/My Profile" chats
ox --root "/path/to/My Profile" chats <id> --json
```

All inspection commands are read-only. `skill create` writes one canonical `skills/<name>/SKILL.md` file and refuses to replace an existing skill. Repeat `--service` to bind multiple services. Use `--instructions-file -` to read the instructions from stdin. `ox profiles` is macOS-only because it discovers the app's iCloud Drive container; `--root` can point directly to a Profile directory on any supported platform.

Artifact JSON listings include `availability`. On macOS, projected iCloud
placeholders are reported as `cloudOnly`; listing them never starts a download,
and selecting one fails clearly until another client materializes its content.

If macOS denies access to iCloud Drive, grant the terminal or agent host access in System Settings → Privacy & Security → Files & Folders.

## Inspect services

Service inspection is offline and does not start the iOS app or Chrome:

```sh
ox --repository /path/to/repository service list
ox --repository /path/to/repository service inspect -s mail.google.com
ox --repository /path/to/repository service actions -s mail.google.com --json
ox --repository /path/to/repository service skills -s mail.google.com --json
```

Repository origins may be local paths, loopback Git URLs, or HTTPS Git URLs.
Use `ox repository serve <path-or-url>` to expose a temporary read-only snapshot
on localhost. Private HTTPS repositories are cloned with the developer's Git
credentials before being served; credentials are never embedded in the URL.

Inspect an action before invoking it. The full manifest shows its input schema and whether it requires authentication or approval.

## Select a runtime session

List sessions in the selected runtime before targeting a live command:

```sh
ox sessions
ox --runtime chrome sessions
```

An iOS session is a service and uses its domain as the stable session ID. The
iOS list therefore includes every service, whether or not its web page is
currently resident. A Chrome session is a tab in Ox's managed Chrome window
and uses its DevTools target ID. Tabs in a normal Chrome profile are not listed.

Pass a listed ID through the global, position-independent `--session` option:

```sh
ox --session mail.google.com service invoke mail.google.com:listAccounts --args '{}'
ox --runtime chrome --session <tab-id> service eval mail.google.com --script 'return document.title;'
```

On iOS, the selected session must match the command's service domain. In Chrome,
the selected tab must already be on the requested service's domain. Selecting
an unmanaged Chrome tab does not adopt it as an Ox-managed background tab.

## Use headed Chrome

Select Chrome with the global, position-independent `--runtime chrome` option:

```sh
ox --runtime chrome service status
ox --runtime chrome service auth mail.google.com
ox --runtime chrome service invoke mail.google.com:listAccounts --args '{}'
```

The first live command that needs a page launches Google Chrome Stable. Ox uses one persistent profile that is separate from your normal Chrome profile, so service sign-ins survive CLI commands and Chrome restarts without changing your everyday browser data.

The profile is stored at:

```text
macOS:   ~/Library/Application Support/Ox/Chrome/
Windows: %LOCALAPPDATA%\Ox\Chrome\
Linux:   $XDG_DATA_HOME/ox/chrome/
```

Override Chrome discovery or profile storage when needed:

```sh
OX_CHROME_PATH="/path/to/Google Chrome" ox --runtime chrome service open example.com
OX_CHROME_PROFILE="/path/to/profile" ox --runtime chrome service open example.com
```

Chrome keeps one managed background tab per service. `service open` brings that managed page to the foreground. `service auth` reuses one clean foreground page in the Ox Chrome window for sign-in and waits until the service reports that authentication succeeded. `service bot-control` reuses the same page for a CAPTCHA or other human-verification step. The window and handoff page remain open for later commands. Enter credentials and complete challenges yourself; Ox does not read or forward the answers.

Available live commands include:

```sh
ox --runtime chrome service status
ox --runtime chrome service invoke <domain>:<action> --args '<json>' [--approve]
ox --runtime chrome service eval <domain> --script '<javascript>'
ox --runtime chrome service reload <domain>
ox --runtime chrome service open <domain>
ox --runtime chrome service auth <domain>
ox --runtime chrome service bot-control <domain> --args '<json>'
ox --runtime chrome service sync
```

`service status` and `service sync` do not launch a stopped browser. Other live commands launch Chrome lazily when required. Operations for the same service are serialized; different service domains can run concurrently.

### Approvals and trust

An approval-gated action stops unless the invocation includes `--approve`:

```sh
ox --runtime chrome service invoke example.com:changeSomething \
  --args '{"value":"new value"}' \
  --approve
```

Only pass `--approve` when you intend the action's external effect.

The Chrome runtime is a local developer and automation harness. It runs service action code inside authenticated pages and does not provide the iOS app's credential-firewall guarantee. Use it only with trusted service definitions and trusted local operators. See [Security](https://github.com/ziyzhu/openox/blob/main/docs/SECURITY.md) for the complete threat model.

## Test services offline

Service action tests run production `actions.ts` code in iOS WebKit while mitmproxy serves committed responses from the service's `actions.har`. Replay cases live in `replay.ts` or an adjacent `replay.cases.json` when captured output would overwhelm the TypeScript source. Requests absent from the HAR are terminated locally and never reach the internet. From the repository, use the lifecycle-owning harness with a claimed numbered QA simulator:

```sh
bun run test:services --repository /path/to/service-repository --device ox-qa-1
bun run test:services <domain>:<action>:<case> --repository /path/to/service-repository --device ox-qa-1
```

The harness derives proxy, registry, and debug ports from the device suffix, builds and serves the current registry, launches a fresh DEBUG app with the service proxy, synchronizes it, executes replay serially, and cleans up. Simulator logs remain available after failures.

Import an existing capture or record a public action through the fail-closed Chrome harness:

```sh
ox --runtime chrome service test --import <domain>:<action> --har /path/to/capture.har --args '{}'
ox --runtime chrome service test --record <domain>:<action> --args '{}'
```

Import and record update the service's `replay.ts` and sanitized `actions.har`. Fixture authoring remains Chrome-based because it uses CDP request tracing, but replay runs only in the iOS Simulator. Recording approval-gated actions requires `--allow-live-write` because the initial recording reaches the real service. Replay itself is offline and can safely exercise those writes against recorded responses.

## Use the iOS runtime

iOS is the default, so `--runtime ios` is optional:

```sh
ox service status
ox service invoke <domain>:<action> --args '<json>'
ox service eval <domain> --script 'return document.title;'
ox service reload <domain>
ox service sync
```

Live iOS commands require a running DEBUG build of Ox and its debug WebSocket. Set `OX_DEBUG_ENDPOINT` when the app is not using the default endpoint:

```sh
OX_DEBUG_ENDPOINT=ws://127.0.0.1:9101 ox service status
```

Sign-in, approvals, and human verification happen in the iOS app. `service open`, `service auth`, and `service bot-control` are Chrome-only handoff commands.

## Command reference

```text
ox profiles [--json]
ox --root <path> memory
ox --root <path> soul
ox --root <path> skills [name] [--json]
ox --root <path> artifacts [filename] [--json]
ox --root <path> chats [id] [--json]
ox --root <path> skill create <name> --description <text> (--instructions <text> | --instructions-file <path|->) [--service <domain>]... [--json]

ox herdr [--port 8787] [--session <name>] [--local-only]

ox [--runtime <ios|chrome>] sessions [--timeout 30000]

ox repository inspect <path-or-url>
ox repository validate <path-or-url>
ox repository serve <path-or-url> [--port 8100]
ox --repository <path-or-url> service list [--json]
ox --repository <path-or-url> service inspect -s <domain>
ox --repository <path-or-url> service actions -s <domain> [--json]
ox --repository <path-or-url> service skills -s <domain> [--json]
ox service test [<domain>[:<action>[:<case>]]] [--proxy-port <port>] [--timeout 30000]
ox --runtime chrome service test --import <domain>:<action>[:<case>] --har <path> [--args '{}'] [--update]
ox --runtime chrome service test --record <domain>:<action>[:<case>] [--args '{}'] [--allow-live-write] [--update]
ox [--runtime <ios|chrome>] service status [--timeout 30000]
ox [--runtime <ios|chrome>] service invoke <domain>:<action> [--args '{}'] [--approve] [--timeout 30000]
ox [--runtime <ios|chrome>] service eval <domain> --script '<javascript>' [--timeout 30000]
ox [--runtime <ios|chrome>] service reload <domain> [--timeout 30000]
ox --runtime chrome service open <domain> [--timeout 30000]
ox --runtime chrome service auth <domain> [--timeout 300000]
ox --runtime chrome service bot-control <domain> --args '{}' [--timeout 300000]
ox [--runtime <ios|chrome>] service sync [--timeout 60000]
```

Global options can appear anywhere in the command:

```sh
ox --runtime chrome service status
ox service --runtime chrome status
ox service status --runtime=chrome
ox service --session mail.google.com eval mail.google.com --script 'return document.title;'
```

Use `ox --help`, `ox service --help`, or a live subcommand's `--help` for the current CLI syntax.

## Troubleshooting

**Google Chrome was not found**

Install Google Chrome Stable or set `OX_CHROME_PATH` to its executable.

**An action requires sign-in**

```sh
ox --runtime chrome service auth <domain>
```

Finish signing in in the foreground Chrome window. Do not use `service open` as a substitute for the clean authentication handoff.

**An action requires approval**

Review the action and its arguments. If you intend the external change, invoke it again with `--approve`.

**The iOS debug WebSocket cannot connect**

Confirm that a DEBUG build of Ox is running and that `OX_DEBUG_ENDPOINT` matches the app's configured endpoint.

**A changed service is still cached**

Chrome reads compiled actions from the selected repository. Run `ox --repository <path-or-url> --runtime chrome service sync` to close managed targets so the next command reloads them. For iOS, refresh the localhost repository snapshot first, then run `ox service sync`.

Closing Chrome is safe: the next live command reconnects or relaunches it with the same Ox-owned profile. Whole-profile reset and per-origin data-clearing commands are not implemented yet.

## Development

From the repository root:

```sh
bun run typecheck
cd ox-cli
bun run build
bun run package:check
```

`package:check` builds the publishable bundle, verifies the tarball contents, installs the tarball into a temporary global prefix, and exercises the installed CLI. Select service repositories explicitly rather than depending on a particular checkout.

## Release

The version in `package.json` is the release source of truth. Update it on `main`, run the package check, then create a matching `ox-cli-v<version>` tag. The publish workflow refuses tags that do not match the package version or commits that are not on `main`.

The first npm release must be published interactively with two-factor authentication:

```sh
cd ox-cli
bun package-check.ts --output /tmp/ox-cli-release
npm publish /tmp/ox-cli-release/openox-cli-0.1.0.tgz --access public
```

After the first release, configure npm Trusted Publishing for the `ziyzhu/openox` repository, `.github/workflows/publish-npm.yml` workflow, and `npm-publish` environment. Subsequent releases are published by pushing the matching tag:

```sh
git tag ox-cli-v0.1.0
git push origin ox-cli-v0.1.0
```

---
name: ox-cli
description: Inspect or manage a Profile or exercise Ox services through the `ox` CLI. Use when discovering iCloud Profiles; reading a Profile's memory, soul, skills, artifacts, or chats; creating a user skill; inspecting service manifests, actions, or skills on disk; testing service actions offline from replay fixtures; selecting the iOS or headed Chrome runtime; checking or opening a service's live page; invoking, evaluating, reloading, authenticating, or completing bot control; or synchronizing live service definitions. For live app chats, logs, agents, sandbox eval, and Server IR conformance, use the ox-debug skill instead.
---

# Ox CLI

`ox` inspects and manages Profiles and exercises service definitions through the iOS app or a headed Chrome profile. Run service source commands from the Ox repository root; consult `ox --help` and the relevant command help before guessing flags. Select Chrome with the position-independent `--runtime chrome`; the default is `ios`.

List targetable runtime sessions with `ox sessions` or
`ox --runtime chrome sessions`. An iOS session is a service and its ID is the
service domain. A Chrome session is a tab in Ox's managed Chrome window and
its ID is the DevTools target ID. Target a live service command with the global,
position-independent `--session <id>` option. The selected iOS service must
match the command domain; a selected Chrome tab must already be on that domain.
Normal-profile Chrome tabs are outside the Ox runtime and are not listed.

Keep adjacent surfaces on their intended tools:

- Use `ox --root <path>` for files in a local or iCloud-synced Profile.
- Use `ox` for service manifests, actions, skills, and live service invocation.
- Use `bun run debug` for live app chats, logs, agents, sandbox eval, and Server IR conformance (the ox-debug skill).
- Use `sim` for every iOS Simulator interaction.

## Connect Ox to local Herdr agents

Run `ox herdr` on the Mac hosting Herdr to start a foreground Streamable HTTP
MCP bridge and a managed foreground Tailscale Serve process. The command prints
the resulting tailnet-only HTTPS endpoint, refuses to replace existing Serve
configuration, and stops sharing when it exits. Use `--port` to change the
loopback port, the global `--session` option to select a named Herdr session,
and `--local-only` to skip Tailscale. The bridge exposes bounded agent details,
detection diagnostics, prompting, reads, state waits, workspace/tab/worktree
inspection, pane/process inspection, literal output waits, workspace/tab
creation and naming, worktree creation and opening, supported agent starts and
naming, focus handoff, notifications, and bounded artifact transfer. Ask an
agent to save an artifact inside its working directory and report the relative
path, then use `agent_artifact_get` to return it as standard MCP image or
embedded-resource content. `agent_artifact_list` finds recent supported files
when the path is unknown. Both tools resolve symlinks within the agent working
directory and reject files above the MCP transfer limit. Workspace/tab closure
and non-forced worktree removal require explicit confirmation. It deliberately
excludes arbitrary shell execution, environment or agent-argument injection,
regular-expression matching, raw keystrokes, pane closure, forced worktree
removal, direct pane layout mutation, and Herdr maintenance.

## Inspect a Profile

List iCloud Profiles on macOS, then point `--root` directly at a returned folder:

```sh
ox profiles [--json]
ox --root <path> memory
ox --root <path> soul
ox --root <path> skills [name] [--json]
ox --root <path> skill create <name> --description <text> (--instructions <text> | --instructions-file <path|->) [--service <domain>]... [--json]
ox --root <path> artifacts [filename] [--json]
ox --root <path> chats [id] [--json]
```

`ox profiles` scans the Ox iCloud Drive container and prints each Profile's
name and absolute root; `--json` also includes its id, creation date, and
version. The CLI does not infer the iOS app's device-local active Profile. The
global `--root` option is position-independent. Reading iCloud Drive requires
the calling terminal or agent host to have Files & Folders access. On an access
denial, ask the user to enable iCloud Drive for that host in System Settings →
Privacy & Security → Files & Folders, then retry.

The Profile inspection commands are read-only. With no name or id, collection
commands list entries. Selecting an entry streams the skill, artifact, or JSONL
transcript; `chats <id> --json` emits one JSON array of turns.
Artifact JSON listings report `availability` as `local` or `cloudOnly` on
macOS. Listing does not download cloud-only content, and selecting a cloud-only
artifact fails clearly instead of implicitly materializing it.

`skill create` writes one canonical `skills/<name>/SKILL.md` file and refuses to
replace an existing skill. Names are normalized to lowercase kebab-case. Repeat
`--service` to bind multiple service domains; comma-separated values are also
accepted. Pass `--instructions-file -` to read the body from stdin.

## Inspect repository services without a running app

Select a local checkout, localhost Git URL, or authenticated HTTPS Git URL:

```sh
ox --repository <path-or-url> service list [--json]
ox --repository <path-or-url> service inspect -s <domain>
ox --repository <path-or-url> service actions -s <domain> [--json]
ox --repository <path-or-url> service skills -s <domain> [--json]
ox repository validate <path-or-url>
ox repository serve <path-or-url> [--port 8100]
```

`repository serve` clones remote origins through the developer's existing Git
credentials or snapshots generated Server IR from a local checkout. It serves a
temporary read-only Git repository on loopback and never commits into the source
checkout. Use it for private GitHub repositories because the app accepts no
embedded Git credentials.

Inspect actions before invoking one. Check `requireAuth`, `requireApproval`, and its input schema in the full manifest.

### Author service skills

Use the `system:create-skill` instructions in `ios/ios/Chat/BuiltInSkills.swift` as the design guide for triggers, workflow boundaries, validation examples, and execution-prompt style. Adapt only its design guidance: `ox skill create` writes user-owned `skills/<name>/SKILL.md` files and does not create registry service skills.

Create a service skill in the independent OpenOx Services checkout at `src/services/web/<domain>/skills/<name>/SKILL.md`. Use a short lowercase kebab-case name without a namespace, matching `name` and `description` frontmatter, and include only `SKILL.md`; bundled resources and `agents/openai.yaml` are unsupported. Inspect the service manifest and actions first, and mention only capabilities the service exposes.

Run the service repository's build, then validate with `ox --repository <service-repository> service skills -s <domain> --json`. Never hand-edit generated Server IR.

## Exercise services in the running DEBUG app

Use these through the app's debug WebSocket:

```sh
ox sessions [--timeout 30000]
ox service status [--timeout 30000]
ox service invoke <domain>:<action> --args '<json>' [--timeout 30000]
ox service eval <domain> --script '<javascript>' [--timeout 30000]
ox service reload <domain> [--timeout 30000]
ox service sync [--timeout 60000]
```

## Test services offline

Use committed cases from `replay.ts` or `replay.cases.json` and responses from `actions.har`.
Replay is fail-closed: unmatched requests are terminated locally.

```sh
bun run test:services -- <domain>[:<action>[:<case>]] --repository <service-repository> --device <claimed-ox-qa-N>
OX_SERVER_SOURCE=<service-source>/web ox --repository <generated-repository> --runtime chrome service test --import <domain>:<action>[:<case>] --har <path> [--args '{}'] [--update]
OX_SERVER_SOURCE=<service-source>/web ox --repository <generated-repository> --runtime chrome service test --record <domain>:<action>[:<case>] [--args '{}'] [--update]
```

Prefer the lifecycle-owning iOS harness for authoritative replay. It claims the
numbered QA tuple, builds and serves Ox Server, launches the app with the
service proxy, and cleans up while preserving logs. Use explicit Chrome replay
only for a fast local check. Import and record remain Chrome-based and update
the service-local test and HAR. Recording reaches the live service;
approval-gated actions require explicit user authorization and
`--allow-live-write`. Replay never permits unmatched traffic onto the internet.

## Exercise services in headed Chrome

Chrome uses one persistent Ox-owned profile with an Ox-themed frame and
launches lazily for commands that need a service page. `status` and `sync` do
not launch a stopped browser.

```sh
ox --runtime chrome sessions [--timeout 30000]
ox --runtime chrome service status
ox --runtime chrome service invoke <domain>:<action> --args '<json>' [--approve] [--timeout 30000]
ox --runtime chrome service eval <domain> --script '<javascript>' [--timeout 30000]
ox --runtime chrome service reload <domain> [--timeout 30000]
ox --runtime chrome service open <domain> [--timeout 30000]
ox --runtime chrome service auth <domain> [--timeout 300000]
ox --runtime chrome service bot-control <domain> --args '<json>' [--timeout 300000]
ox --runtime chrome service sync [--timeout 60000]
```

Chrome action targets run in background tabs. `service open` brings the managed,
action-injected target to the foreground without changing its current page.
Authentication and bot-control commands reuse one clean, non-injected handoff
page in the Ox Chrome window and leave it open for the next command. Do not
enter credentials, solve challenges, or handle challenge tokens on the user's
behalf. `--approve` is
required for approval-gated Chrome actions and must only be supplied when the
user's request authorizes the mutation. Override Chrome discovery with
`OX_CHROME_PATH` and profile storage with `OX_CHROME_PROFILE`.

Treat `invoke` as a real action: it may read authenticated data or mutate state. Do not invoke an approval-requiring action unless the user's request authorizes that mutation. Treat `service eval` as arbitrary code in the service page and keep it narrowly scoped to the requested inspection or test.

In iOS, `service reload` closes action admission, waits for active actions,
reloads the page, and resumes queued actions after the service dispatcher is
ready. In Chrome, commands for the same domain are serialized through the
profile lock before `reload` refreshes the managed page.

For iOS, use `service sync` after the selected repository server contains rebuilt
service changes. Chrome reads compiled `manifest.json` and `actions.js` from the
repository selected by `--repository`; its `service sync` closes tracked managed
targets so the next live command reopens them from that repository.

## Live connection workflow

The iOS `status`, `invoke`, `eval`, `reload`, and `sync` commands require a
running DEBUG app and its debug WebSocket. On connection failure:

1. Confirm the app is running with `sim`, without touching the human-reserved `ox-qa` device.
2. Run `ox service status` as the smallest connectivity probe.
3. Check `OX_DEBUG_ENDPOINT` when the app uses a non-default endpoint.
4. Inspect `bun run debug dev logs --level warning` before widening to device logs.

Prefer command output over assumptions. Report the exact command, target service, and relevant failure text when blocked.

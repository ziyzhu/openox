---
name: setup
description: Set up an OpenOx checkout for local development or Pi, including CLI and skill dependencies, simulator provisioning, iOS signing, App Store authentication, bundled services, and first launch. Use when a contributor asks to get OpenOx running, configure a coding agent, or diagnose a setup failure.
---

# Setup

Help the contributor reach a verified working environment. First determine whether they need the CLI, the iOS app, coding-agent setup, or commit readiness. Inspect existing tools and configuration before changing anything; preserve their chosen simulator, bundle identifier, Apple team, and local data. Read the repository [AGENTS.md](../../../AGENTS.md) and relevant package documentation. Keep machine-specific values in ignored local files.

## Source checkout and Ox CLI

Install [Bun](https://bun.sh/) 1.3 or newer. Check `bun --version` and `ox --help`, then run from the checkout root:

```sh
bun install
bun run typecheck
(cd apps/cli && bun run build && bun link)
ox --help
ox host list --help
```

- Use `bun run typecheck` as the first source check. Follow [apps/cli/README.md](../../../apps/cli/README.md) for standalone installation or package checks.
- Run `bun link` inside `apps/cli`, not `bun link @openox/cli` at the workspace root; the latter creates a dependency loop with the existing workspace.
- If help still lists old top-level `discover`, `logs`, or `service` commands, check `command -v ox`. The current CLI groups those operations under `host`. Resolve stale installations with their original package manager or adjust PATH; do not overwrite an unrelated executable.
- Rebuild after source changes or switching worktrees. A global source link follows one checkout; concurrent agents should use `bun apps/cli/src/ox.ts` from their own checkout when they cannot share the linked build.
- On Linux, limit setup to the CLI, repository tooling, and coding-agent configuration.

## iOS tools and simulator pool

Use macOS with Xcode supporting the assigned iOS 26 and iOS 27 runtimes. Install components in **Xcode > Settings > Components**, following [Apple's component installation guide](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components). An older Xcode may need upgrading before it can use a newer runtime. Keep existing Xcode installations and devices until replacements work; never erase simulator data to resolve a missing runtime.

Use the agent-independent `ios-simulator` skill for native-tool installation checks,
target discovery, and interaction. UI automation needs both the idb client and
companion; local screenshots/video need only `simctl`. If the skill is unavailable,
consult installed native CLI help. Resolve the chosen name to a unique UDID and
pass it explicitly; never rely on a default booted target.

- Follow Simulator Setup in `AGENTS.md`: `ox-1` through `ox-3` run iOS 26; `ox-4` and `ox-5` run iOS 27. Use [scripts/qa-config.ts](scripts/qa-config.ts) for all assigned ports. The QA harness accepts only those five names.
- Missing iOS 27 support blocks `ox-4` and `ox-5`; do not substitute iOS 26 or change the pool policy. Partial setup can proceed on the first three reserved targets.
- Before touching a device, coordinate ownership with other agents and inspect repository QA claims. Those claims cover repository runners only; no activity signal proves exclusive ownership. Clone only free, shutdown simulators; preserve originals as backups and verify replacements with `xcrun simctl list devices available --json`.
- When no suitable simulator exists, create it in Xcode's **Devices and Simulators** window using the assigned runtime. After reserving a suitable iOS 26 baseline, for example:

```sh
xcrun simctl clone "$BASELINE_UDID" ox-1
xcrun simctl clone "$OX1_UDID" ox-2
xcrun simctl clone "$OX1_UDID" ox-3
```

Use `ox-1` as the common website/provider baseline. Cloning does not establish that credentials or website logins still work. Verify configuration, default model, provider credentials, and website logins after building and installing. For explicit cookie/local-storage transfers between running, reserved targets, consult `bun run sim:bootstrap --help` and the [website-state limitations](../release/references/storage.md#website-state). Other website state and provider settings need separate setup.

Resolve `BASELINE_UDID` and, after cloning, `OX1_UDID` from the inventory before running those commands. `scripts/simulator.ts` shares native device/runtime checks and PID claims with the test runners. `scripts/ios.ts` composes native commands for the QA harness without an external wrapper CLI. Claims coordinate repository runners only; they do not replace agent ownership checks. `scripts/bootstrap.ts` owns the explicit credential/artifact/website-state setup behind `bun run sim:bootstrap`.

## iOS signing and local configuration

- Copy `apps/ios/Local.xcconfig.example` to the ignored `apps/ios/Local.xcconfig` if it does not exist. Set `OX_BUNDLE_IDENTIFIER` to the contributor's intended identifier and `OX_DEVELOPMENT_TEAM` to their Apple Developer team. Enable `CODE_SIGNING_ALLOWED = YES` for a build that needs Keychain. Do not put a team ID, certificate, profile, or credential in tracked files.
- Check for a usable local signing identity with `security find-identity -v -p codesigning`. An App Store Connect API key or a certificate listed by `asc` does not supply the certificate's private key to this Mac. If the identity is absent, guide the contributor through Xcode's Apple Account and automatic signing setup, or use an existing private key they control. Do not create, revoke, or replace a certificate as a routine setup step.
- After building, inspect the actual `.app` with `codesign -dv --verbose=4 <app>` and `codesign -d --entitlements :- <app>`. For a Keychain `errSecMissingEntitlement` startup failure, check the app identifier, access groups, and embedded entitlements before changing simulator data. Apple's [Keychain entitlement diagnosis](https://developer.apple.com/documentation/security/errsecmissingentitlement) explains the failure. A successful build alone does not establish that Keychain works.

## First simulator run

- Reserve an available numbered simulator and use its matching ports. Initialize the shared website/provider baseline before testing. Rebuild and reinstall after switching worktrees.
- Build bundled services with `xcodebuild -project apps/ios/Ox.xcodeproj -scheme ios -configuration Debug -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA" build`. Use a task-specific path outside the repository. Install the resulting `Build/Products/Debug-iphonesimulator/Ox.app` with `xcrun simctl install "$UDID" "$APP_PATH"`, then launch with `SIMCTL_CHILD_OX_DEBUG_ENDPOINT="ws://127.0.0.1:$DEBUG_PORT" xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID"`.
- To test loading a local repository separately, start `ox --repository examples/repository repository serve --port <registry-port>`, verify `curl -fsS http://127.0.0.1:<registry-port>/health`, and relaunch with `SIMCTL_CHILD_OX_SERVICES_ENDPOINT=http://localhost:<registry-port>/repository.git` in the launch environment.
- Verify the expected normal UI using the shared skill's AX/capture loop, not just launch success. When installed apps share a display name, launch by bundle identifier rather than tapping the first matching Home Screen icon.
- For CLI access, enable **Settings > Host > Allow connections** and keep Ox foreground. Physical-device and Release Hosts require Tailscale on both devices. A Debug Simulator launch can explicitly opt into localhost with `SIMCTL_CHILD_OX_HOST_LOOPBACK=1` in the simctl launch environment; it binds only `127.0.0.1` on the assigned port and uses the same ordinary Host API. This flag is compiled out on physical devices and Release builds; a normal relaunch restores Tailscale-only access. `OX_DEBUG_ENDPOINT` selects the port, not the ingress mode. Verify `ox --host ws://127.0.0.1:<debug-port> host describe` for loopback, or use `ox host list`/the tailnet address for Tailscale. A `starting` log is not readiness. Preserve failure logs, never add unrestricted listeners or bypass approvals, and restore temporary settings afterward.
- Use Mock for a no-cost smoke test; real provider calls require authorization. Enter provider credentials through Ox's secure UI when needed. The ignored `secrets/API_KEYS.json` is only for local test bootstrap; never request a key in chat or pass it on a command line.

## Device templates

`bun run sim:launch --device ox-N --template <json>` builds, installs, and launches
with declarative on-device data. `--app <Ox.app>` reuses a matching Debug Simulator
artifact; `bun run sim:bootstrap --device ox-N --template <json>` applies to the
installed artifact and relaunches it. Reserve the target first. Setup uses a local
startup file, not Host access or a model call; Release and physical builds cannot
apply templates. `--loopback` only opts into Debug localhost ingress and does not
enable Host connections.

The TypeScript contract is `scripts/template-schema.ts`; `templates/basic.json`
is a runnable example. `--schema` prints JSON Schema directly from that contract.
`--validate --template <json>` checks references and external
inputs without a simulator. Omitted fields remain unchanged. Profiles get a
run-owned name suffix; each application creates new Profiles rather than merging
into existing data. Result manifests map template-local Profile/chat IDs to actual
IDs. Settings support the existing Ox themes, not an invented system theme.

UserDefaults supports strings, booleans, numbers, arrays, `{ "dictionary": {...} }`,
`{ "data": "<base64>" }`, and `{ "date": "<UTC ISO timestamp>" }`; explicit `remove`
clears keys. Typed settings and raw preferences cannot conflict. Profile files can
populate nested skills as well as shared content; chat files own attachment bytes.
Messages support user text/attachments and assistant text/reasoning; `packageFrom`
imports an existing `.chat` package instead of `messages` for richer historical tool
results and presentation. Neither path runs historical tools or calls a model.

Credentials use `secret: { "env": "NAME" }` or `secret: { "fromFile": "path" }`;
paths resolve relative to the template JSON. `--allow-keychain` authorizes declared
writes/replacements. Named secrets require private flat JSON string-field objects;
provider credentials use the normal binding owner. `removeProviders`, `removeSecrets`,
and `removeAccounts` explicitly clear declared credentials under the same authorization.
Raw OAuth/Secret accounts and
explicit bindings support exact credential state. Never put credentials in tracked
JSON or pass their values as arguments.

`bun run sim:website-export --device ox-N --output /private/path/session.snapshot`
captures cookies/local storage from an already reachable authorized Host. A template
can restore `websiteState: { "restoreFrom": "/private/path/session.snapshot" }`.
Restoration replaces those app-wide data types, leaves IndexedDB unchanged, and does
not prove authentication: verify required websites after restoring. Sessions can
expire or be device-bound. Snapshot files are credential-bearing, mode 0600, and
must remain outside Git.

`storage` entries name `documents`, `applicationSupport`, `appGroup`, or `caches`,
a domain-relative destination `path`, external source `from`, and `provenance`
(`build`, `storageVersion`). `--allow-storage-replay` explicitly authorizes replacing
these paths while the app is stopped, retaining prior contents in private evidence.
It also gates raw active-Profile/Secret-index preferences. This covers exact Profile,
repository, schedule, share-inbox, and temporary-cache representations without new
migrators. Logs, template control paths, overlapping sources/destinations, and linked inputs
are rejected. Snapshot inputs are streamed and hashed; restored bytes are verified
before launch. Limits are 512 MiB/100,000 entries per input and 1 GiB total. Predecessor evidence must come from the actual older build; provenance
labels alone are not proof. Normal startup still runs `StorageMigrator`; never erase
or uninstall as upgrade setup. Device-bound bookmarks and OS permissions still
require provisioning. Unknown template fields fail rather than being ignored.

Evidence includes a redacted manifest, original changed preferences, storage backups,
AX tree, screenshot, and fresh logs outside the repository. Credential-bearing input
is deleted after loading. Setup is not atomic across storage owners; inspect the
manifest after failure. No automatic cleanup/rollback is provided yet: leave run-owned
Profiles for review, remove them through Profile Settings, and restore changed
preferences deliberately using `preferences-before.plist`. Keychain and website-state
changes are not automatically undone. The launcher leaves the target running and
releases its runner claim; coordinate continued interactive ownership.

## App Store authentication

Use the [App Store Connect CLI](https://asccli.sh), installed by Homebrew as **`asc`**. Inspect an existing installation before adding another tool; the separate Homebrew formula `asccli` has different flags and authentication storage and is not required.

```sh
# Install only if asc is missing.
brew install asc
asc --version
asc versions list --help
asc auth status
```

Installation alone does not configure authentication. If credentials are missing, use an existing App Store Connect API key and local `.p8` file:

```sh
asc auth login --key-id <key-id> --issuer-id <issuer-id> \
  --private-key /absolute/path/to/AuthKey.p8 --name <account>
```

Never paste private-key contents into chat, command arguments, or tracked files. Do not create or revoke API keys or signing certificates as a routine setup step. Missing credentials block App Store release work, not local builds or commits. Follow `AGENTS.md` for commit requirements; committing requires no App Store queries or version checks.

## Pi and portable agent skills

Run Pi from the checkout root. Pi loads `AGENTS.md` and discovers repository skills in `.agents/skills/` natively. Review the skills and trust this checkout when prompted; `/trust` saves the decision. Noninteractive runs need a saved trust decision or explicit `--approve` after review. No `.pi/settings.json`, provider pin, or MCP server is required. Keep personal model choices in `~/.pi/agent/settings.json`.

Simulator workflows use the agent-independent `ios-simulator` skill maintained in dotfiles at `.agents/skills/ios-simulator/SKILL.md`, exposed through `~/.agents/skills/ios-simulator`. Run dotfiles `./setup check` and `./setup apply` to audit/apply its discovery links. Other contributors can use their own shared skill installation or native CLI help; the test runners require only Bun and the native iOS tools, not a coding-agent runtime or external wrapper checkout. Inspect existing destinations before changing links; never replace another installation blindly. Reload the coding agent's skills after updates where required.

Additional browser/proxy skills are task-specific, not prerequisites for basic Pi use.

## Completion

Report what worked, the exact remaining blockers, and the smallest next action. Distinguish CLI, iOS runtime, signing, website/provider state, coding-agent, and commit readiness. Do not claim setup is complete based only on dependency installation, a green build, or a Mock turn.

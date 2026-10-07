---
name: onboarding
description: Set up an OpenOx checkout for local development or Pi, including CLI and skill dependencies, simulator provisioning, iOS signing, App Store authentication, bundled services, and first launch. Use when a contributor asks to get OpenOx running, configure a coding agent, or diagnose a setup failure.
---

# Onboarding

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

Install [sim](https://github.com/ziyzhu/ios-cli) from a separate source checkout:

```sh
# Run inside the ios-cli checkout.
bun install
bun link
sim --help
```

UI automation also requires [idb_companion](https://github.com/facebook/idb); follow its upstream installation instructions. Verify:

```sh
command -v sim idb_companion
xcode-select -p
sim devices
```

Use the `sim-cli` skill for iOS interaction; see the coding-agent setup section below to install it. If unavailable, consult `sim --help`, command-specific help, and `sim agent-context`. Never guess flags or build directly with `xcodebuild`.

- Follow Simulator Setup in `AGENTS.md`: `ox-1` through `ox-3` run iOS 26; `ox-4` and `ox-5` run iOS 27. Use [scripts/qa-config.ts](scripts/qa-config.ts) for all assigned ports. The QA harness accepts only those five names.
- Missing iOS 27 support blocks `ox-4` and `ox-5`; do not substitute iOS 26 or change the pool policy. Partial setup can proceed on the first three reserved targets.
- Before touching a device, coordinate ownership with other agents and inspect recent activity in `~/.sim-cli/logs/invocations.jsonl`. Clone only free, shutdown simulators; preserve originals as backups and verify replacements with `sim devices`.
- When no suitable simulator exists, create it in Xcode's **Devices and Simulators** window using the assigned runtime. After reserving a suitable iOS 26 baseline, for example:

```sh
sim devices clone <free-baseline-name-or-udid> ox-1
sim devices clone ox-1 ox-2
sim devices clone ox-1 ox-3
```

Use `ox-1` as the common website/provider baseline. Cloning does not establish that credentials or website logins still work. Verify configuration, default model, provider credentials, and website logins after building and installing. For explicit cookie/local-storage transfers between running, reserved targets, consult `bun run sim:bootstrap --help` and the [website-state limitations](../migrate/references/storage.md#website-state). Other website state and provider settings need separate setup.

`scripts/simulator.ts` shares device/runtime checks and PID claims with the test runners. Claims coordinate repository runners only; they do not replace agent ownership checks. `scripts/bootstrap.ts` owns the explicit credential/artifact/website-state setup behind `bun run sim:bootstrap`.

## iOS signing and local configuration

- Copy `apps/ios/Local.xcconfig.example` to the ignored `apps/ios/Local.xcconfig` if it does not exist. Set `OX_BUNDLE_IDENTIFIER` to the contributor's intended identifier and `OX_DEVELOPMENT_TEAM` to their Apple Developer team. Enable `CODE_SIGNING_ALLOWED = YES` for a build that needs Keychain. Do not put a team ID, certificate, profile, or credential in tracked files.
- Check for a usable local signing identity with `security find-identity -v -p codesigning`. An App Store Connect API key or a certificate listed by `asc` does not supply the certificate's private key to this Mac. If the identity is absent, guide the contributor through Xcode's Apple Account and automatic signing setup, or use an existing private key they control. Do not create, revoke, or replace a certificate as a routine onboarding step.
- After building, inspect the actual `.app` with `codesign -dv --verbose=4 <app>` and `codesign -d --entitlements :- <app>`. For a Keychain `errSecMissingEntitlement` startup failure, check the app identifier, access groups, and embedded entitlements before changing simulator data. Apple's [Keychain entitlement diagnosis](https://developer.apple.com/documentation/security/errsecmissingentitlement) explains the failure. A successful build alone does not establish that Keychain works.

## First simulator run

- Reserve an available numbered simulator and use its matching ports. Initialize the shared website/provider baseline before testing. Rebuild and reinstall after switching worktrees.
- Build, install, and launch bundled services with `sim --device <simulator> run <bundle-id> --project apps/ios/Ox.xcodeproj --scheme ios --env OX_DEBUG_ENDPOINT=ws://127.0.0.1:<debug-port> --force`.
- To test loading a local repository separately, start `ox --repository examples/repository repository serve --port <registry-port>`, verify `curl -fsS http://127.0.0.1:<registry-port>/health`, and relaunch with `--env OX_SERVICES_ENDPOINT=http://localhost:<registry-port>/repository.git`.
- Confirm the normal UI with `sim --device <simulator> describe` and a screenshot. If accessibility frames disagree with the screenshot after a reboot or reinstall, restart only that reserved device's `idb_companion` before trusting coordinates. When installed apps share a display name, launch by bundle identifier rather than tapping the first matching Home Screen icon.
- For CLI access, enable **Settings > Host > Allow connections** and connect Tailscale on both devices. `OX_DEBUG_ENDPOINT` selects the port, not a loopback listener; use `ox host list` or `ox --host ws://<tailscale-address>:<debug-port> host describe`. A `waiting for Tailscale` log is not listener readiness. If the Host never reports `ready`, preserve its logs and resolve ingress before running live authoring or service checks; do not bypass the transport's access restrictions. A simulator reporting only `en0:wifi` despite a healthy Mac VPN does not establish usable VPN ingress; use a reachable Host for live checks. Restore temporary settings afterward and keep diagnostics outside the repository.
- Use Mock for a no-cost smoke test; real provider calls require authorization. Enter provider credentials through Ox's secure UI when needed. The ignored `secrets/API_KEYS.json` is only for local test bootstrap; never request a key in chat or pass it on a command line.

## App Store authentication and commit readiness

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

Never paste private-key contents into chat, command arguments, or tracked files. Do not create or revoke API keys or signing certificates as a routine setup step. Missing credentials block the release check, not local builds; do not claim commit readiness without them. Before committing, follow all version rules in `AGENTS.md` and make only its required release query:

```sh
asc versions list --app 6802224502
```

An unavailable key or denied API access blocks the prescribed commit check. Report it instead of guessing the released version.

## Pi and portable agent skills

Run Pi from the checkout root. Pi loads `AGENTS.md` and discovers repository skills in `.agents/skills/` natively. Review the skills and trust this checkout when prompted; `/trust` saves the decision. Noninteractive runs need a saved trust decision or explicit `--approve` after review. No `.pi/settings.json`, provider pin, or MCP server is required. Keep personal model choices in `~/.pi/agent/settings.json`.

Simulator workflows also use the external `sim-cli` skill. To make it available across projects, run from your `ios-cli` source checkout:

```sh
mkdir -p "$HOME/.agents/skills"
ln -s "$PWD/skills/sim-cli" "$HOME/.agents/skills/sim-cli"
```

Inspect an existing destination before changing it; do not replace another installation blindly. Pi discovers `~/.agents/skills/` without extra settings. Run `/reload` after installing or editing skills. Use `sim` help as the fallback when the external skill is unavailable.

Additional browser/proxy skills are task-specific, not prerequisites for basic Pi use.

## Completion

Report what worked, the exact remaining blockers, and the smallest next action. Distinguish CLI, iOS runtime, signing, website/provider state, coding-agent, and commit readiness. Do not claim setup is complete based only on dependency installation, a green build, or a Mock turn.

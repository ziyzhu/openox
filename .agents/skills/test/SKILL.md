---
name: test
description: Run and diagnose OpenOx portable CI, CLI/contract E2E checks, standalone CLI installation checks, and explicit local iOS smoke or demo verification. Use for software correctness and verification evidence; real-model behavior belongs to evals and exploratory user simulation to gym.
---

# Test

Verification code lives here: `apps/` owns CLI and iOS checks, `contracts/` owns
Client-Host and Host-Service boundary checks, and `scripts/ci.sh` orchestrates
portable CI. Eval definitions and real-model runs belong to the `evals` skill.
Simulator setup, assigned ports, device validation, and PID claims belong to
`onboarding`. No agent runtime is required to execute these commands.

## Commands

Run from the repository root, or use `bun run --cwd <checkout>`:

```sh
bun run ci
bun run ci --standalone-only --out /tmp/ox-cli-artifacts
bun run test:e2e
bun run test:logs
bun run ci:ios --device ox-1
bun run test:demo --device ox-1
```

`test:e2e` explicitly discovers this skill's `*.test.ts` files. Simulator flows,
release helpers, and eval runners are not automatically executed tests.

## Portable verification

CI requires Bun, Git, and npm, installs with the frozen lockfile, and runs:

- Static repository checks and TypeScript through the `build` skill.
- Real CLI processes against controlled Host and repository fixtures.
- Offline CLI argument/help, log pagination, and stubbed iOS runner safety checks.
- Eval case-definition validation only, without model calls.
- Service-bundle generation and resource consistency.
- Clean-install/consumer checks for the published packages.

Live-target environment variables are cleared and automatic `.env` loading is
disabled. No simulator, provider credentials, OAuth session, or publication is
needed. A green portable run does not verify live iOS or service behavior.

Standalone mode additionally requires platform installation tools such as curl
and tar. It builds, downloads, and installs the current platform's CLI archive,
then verifies version/help, repository validation, discovery, and chat operations
against fixtures with no Bun or Node on PATH. GitHub checks macOS ARM64/Intel and
Linux ARM64/x64 using the same command and pins Bun 1.3.13.

## Local iOS verification

Follow the simulator ownership and baseline rules in repository `AGENTS.md`.
`ci:ios` requires sim, Xcode, an explicitly reserved numbered simulator, and Host
connections already enabled. It never provisions, clones, uninstalls, erases,
changes credentials, or enables Host access.

The bundle comes from `--bundle`, `OX_BUNDLE_ID`, or `apps/ios/Local.xcconfig`.
The default Host uses the selected device's assigned port; VPN ingress can use
`--host ws://<simulator-vpn-address>:9101` for ox-1.

The runner force-builds/installs/launches bundled services through sim, following
[Apple's Simulator workflow](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).
It creates a temporary Mock chat, sends scenario `2`, verifies the completed reply
and visible assistant message, then attempts to restore the prior saved chat.
It only shuts down a simulator it booted. Relaunching can discard an unsaved
temporary chat: use a dedicated QA target, not personal working state.

Screenshots, build results, chat snapshots, and failure logs go in a new directory
outside the repository; `--output` selects its parent. PID claims coordinate these
runners only, not manual sim use or other agents. `test:agent-ui-ios --device ox-1 --app /absolute/Ox.app` exercises the actual
temporary-chat Pi path with native Mock already selected. It checks reasoning,
Markdown, native snippet tools, Stop, committed SQLite history and process reopen.
It requires an idle chat, claims the selected simulator, uses no Host transport,
and restores ordinary launch afterward. `OX_DURABLE_TEMPORARY_SESSION=<UUID>`
enables temporary-chat UI attachment in Debug and Release builds on simulators
and physical devices; it does not enable Host access or adopt persisted Profiles.
Diagnostic RPCs remain restricted to DEBUG Simulator builds. Stopped-process SQLite copies include WAL/SHM
and are diagnostic evidence, not Profile exports or power-loss verification.

`test:demo` checks native preview
presentation and unchanged profile/repository state, not live integrations; use
the `demo` skill for its workflow.

## Evidence

Package-owned `package-check.ts` files verify release artifacts and consumers;
never publish as a test. Model evaluation follows the `evals` skill and exploratory
UI campaigns follow `gym`. Neither replaces live upgrade/auth/service verification.
Committed service/storage replay fixtures are not maintained here.

Report commands, targets, results, limitations, and private evidence paths. State
when real iOS, models, authentication, or services were not exercised. Keep logs,
reports, screenshots, recordings, and predecessor snapshots outside the repository.

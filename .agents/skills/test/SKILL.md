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
bun run ci:ios --device ox-1 --loopback
bun run test:demo --device ox-1
bun .agents/skills/test/apps/ios/settings.ts --device ox-1 --host <ws-url> --app <Ox.app>
bun .agents/skills/test/apps/ios/image-widget.ts --device ox-2 --chat <saved-Mock-QA-chat-seeded-with-0> --app <Ox.app>
bun .agents/skills/test/apps/ios/durable-chat.ts --device ox-1 --app <Ox.app> --evidence /tmp/ox-model-qa --models
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
Checkout fixtures must include untracked files and skip working-tree deletions;
`git ls-files --cached` still lists deleted files until they are staged.

Standalone mode additionally requires platform installation tools such as curl
and tar. It builds, downloads, and installs the current platform's CLI archive,
then verifies version/help, repository validation, discovery, and chat operations
against fixtures with no Bun or Node on PATH. GitHub checks macOS ARM64/Intel and
Linux ARM64/x64 using the same command and pins Bun 1.3.13.

## Local iOS verification

Follow the simulator ownership and baseline rules in repository `AGENTS.md`.
Different simulators still share a checkout's DerivedData build database. Serialize
shared builds, or use `sim --device ox-N build --project apps/ios/Ox.xcodeproj --scheme ios --derived-data /tmp/<campaign>/DerivedData --force`
and launch the resulting `.app` with `sim run --app` on the same explicit device.
Separate DerivedData avoids build-database locks, not concurrent source-generation races.
A matched tap does not prove a native switch changed: wait for stable frames, use
`sim tap ... --duration 0.25` for switch controls, and verify AX value and behavior.
`ci:ios` requires sim, Xcode, an explicitly reserved numbered simulator, and Host
connections already enabled. It never provisions, clones, uninstalls, erases,
changes credentials, or enables Host access.

The bundle comes from `--bundle`, `OX_BUNDLE_ID`, or `apps/ios/Local.xcconfig`.
The default Host uses the selected device's assigned port; VPN ingress can use
`--host ws://<simulator-vpn-address>:9101` for ox-1. `ci:ios --loopback` explicitly
opts a Debug Simulator launch into `127.0.0.1`; it still requires Allow connections,
uses ordinary Host APIs, and is compiled out on physical devices and Release builds.
The opt-in is launch-only; relaunch without it to restore Tailscale-only networking.

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
Markdown, native snippet tools, separate worker ownership and drain-before-restart
for Stop followed by queued input, committed SQLite history and process reopen.
It requires an idle chat, claims the selected simulator, uses no Host transport,
and restores ordinary launch afterward. `OX_DURABLE_TEMPORARY_SESSION=<UUID>`
enables temporary-chat UI attachment in Debug and Release builds on simulators
and physical devices; it does not enable Host access or adopt persisted Profiles.
Diagnostic RPCs remain restricted to DEBUG Simulator builds. Stopped-process SQLite copies include WAL/SHM
and are diagnostic evidence, not Profile exports or power-loss verification.

Keep Mock focused on model streaming, tool loops, handoffs, and model-visible context. Feature-specific regression setup, assertions, and cleanup belong in E2E runners, not new numbered Mock scenarios. The Mock menu is the source of truth for supported inputs; retired numbers fall back to that menu. Removing a Mock regression does not establish replacement coverage.

Bundled skill boundaries use `bun .agents/skills/test/apps/ios/bundled-skills.ts --device ox-N --host ws://<assigned-host>:<assigned-port> --chat <seeded-saved-QA-chat> --temporary-chat <empty-temporary-QA-chat>` after installing a fresh build. Seed the saved Mock chat with `QA bundled skill verification seed. Reply QA only.` before creating the temporary chat; inspect after creation for its prepared ID. It verifies Pi-derived native schemas, canonical package bytes, references/helpers, discovery/search, mutation denial, old-path aliases, paginated Unicode reads, exact multi-edits and diffs, parallel-edit serialization, an editable run-owned copy with cleanup, and trusted activation versus temporary-chat mutation restrictions. After relaunch, wait for `ox host describe` to succeed; `sim run` readiness means frontmost, not Host readiness. Open the saved QA chat before creating the empty temporary chat so both are hydrated without discarding the temporary one. For the default delete-approval policy, leave the app on that Profile's Skills screen and pass `--ui-cleanup`; this confirms deletion of only the run-owned copy without widening policy. Mock `72 bundled` covers model-visible loading and System activation; it is not full workflow verification.

`settings.ts` requires an already reachable Host on the selected simulator's assigned port and an idle saved chat. It exercises language/theme, app-default and conversation-model setters, automatic-model reset, and repository listing/enablement through `ox`, checks validation, no-op results, and hidden compatibility aliases, relaunches the supplied app to verify persistence, and restores the original preferences and saved chat. VM helper namespace changes do not rename persisted Action identifiers; preserve existing approvals and user-authored helper calls. It does not enable Host access, change credentials, or reset data. Host ingress failures block live verification. For authorized local QA, launch the Debug Simulator app with `OX_HOST_LOOPBACK=1`; never widen physical-device/Release access or bypass approvals to make a test pass.

`local-repository.ts --device ox-N --host <ws-url> --chat <saved-QA-chat> --bundle <bundle-id> --domain <qa-draft-domain>` verifies disabled Local mutation refusals against the native Host and byte-identical source, Git, and configuration snapshots. Use enabled Local, an empty run-owned `qa-` web draft, and an idle saved Mock chat seeded with `QA Local repository enablement regression. Reply QA only.` It restores enablement and writes identical source after reenabling; it creates no drafts or commits. Delete the prepared run-owned draft through the normal UI afterward. This checks runtime safety, not real-model prompting.

`durable-chat.ts --models` uses native Mock scenario `23` through the actual UI without Host ingress. It verifies deferred switches, pending no-ops, Stop/failure cancellation, and the next queued turn's model, then runs `23 defaults` to verify default selection/reset, invalid arguments, current-chat isolation, and restoration. It uses the explicit temporary SQLite fixture and restores the normal launch environment; it does not change provider credentials and restores the original new-chat default. This fixture requires automatic or Mock defaults. Default relaunch checks require the Host-based suite; persisted-chat model reload is not covered.

`image-widget.ts` verifies remote/local image display, zoom-viewer handoff, source
validation, artifact rename, model-context separation, process reopen, and remote
failure/retry through `ox` and `sim`. Use a dedicated saved Mock QA chat seeded with
`0` and a fresh app on the assigned loopback Host. It retains run-owned fixtures and
the chat for human review; remove them through normal UI when finished. It never
changes approval policies, provider credentials, or website state. Mock accepts
`execute\n<JavaScript>` for runner-supplied tool calls; keep feature fixtures in E2E
rather than numbered scenarios. After seeding, use the prepared saved ID from
`chat inspect`, not the provisional ID returned by `chat new`.

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

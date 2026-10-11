---
name: test
description: Run and diagnose OpenOx portable CI, CLI/contract E2E checks, standalone CLI installation checks, and explicit local iOS smoke or demo verification. Use for software correctness and verification evidence; real-model behavior belongs to evals and exploratory user simulation to gym.
---

# Test

Verification code lives here: `apps/` owns CLI and iOS checks, `contracts/` owns
Client-Host and Host-Service boundary checks, and `scripts/ci.sh` orchestrates
portable CI. Eval definitions and real-model runs belong to the `evals` skill.
Simulator setup, assigned ports, device validation, and PID claims belong to
`setup`. No agent runtime is required to execute these commands.

## Commands

Run from the repository root, or use `bun run --cwd <checkout>`:

```sh
bun run ci
bun run ci --standalone-only --out /tmp/ox-cli-artifacts
bun run test:e2e
bun run test:logs
bun run test:host-macos --app /absolute/OxHost.app --output /tmp/ox-macos-evidence
bun run ci:ios --device ox-1 --loopback
bun run ci:ios --device ox-1 --loopback --app /absolute/Ox.app
bun run test:demo --device ox-1
bun .agents/skills/test/apps/ios/settings.ts --device ox-1 --host <ws-url> --app <Ox.app>
bun .agents/skills/test/apps/ios/image-widget.ts --device ox-2 --conversation <saved-Mock-QA-conversation-seeded-with-0> --app <Ox.app>
bun .agents/skills/test/apps/ios/profile-files.ts --device ox-3 --conversation <seeded-saved-Mock-QA-conversation> --app <Ox.app>
bun .agents/skills/test/apps/ios/ox-errors.ts --device ox-2 --host <ws-url> --conversation <idle-QA-conversation>
bun .agents/skills/test/apps/ios/durable-conversation.ts --device ox-1 --app <Ox.app> --evidence /tmp/ox-model-qa --models
```

Keep documented runner paths and help flags executable; verify canonical and compatibility spellings through real processes before using a live target.

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
then verifies version/help, repository validation, discovery, and conversation operations
against fixtures with no Bun or Node on PATH. GitHub checks macOS ARM64/Intel and
Linux ARM64/x64 using the same command and pins Bun 1.3.13.

## Local macOS verification

`test:host-macos` launches the actual signed Debug `ai.openox.host.local` app as a
menu-bar process on reserved localhost port 19876. It verifies Mock conversations, native
JavaScript, cancellation, explicit UI-capability rejection, graceful SIGTERM,
restart persistence, browser-Origin rejection, disabled Host access, and quitting
during an active run. It refuses existing Mac Host processes and uses the app's own sandbox,
retains one QA conversation for review, disables connections afterward, and stops its
processes. It does not run real providers, OAuth, native iOS services, scheduling,
or Tailscale verification. Debug loopback is explicit; Release stays Tailscale-only.
For Mac UI verification, use System Events accessibility to open the status menu,
toggle connections, present an existing service page, and close/reopen its window.
Verify the same page identity/DOM survives and CLI access continues without a
window. Capture only the Host UI outside Git; screenshots require macOS Screen
Recording permission, which must not be bypassed.
For a Release smoke, launch the Release app with `OX_HOST_LOOPBACK=1`, verify
localhost still refuses connections, and use the actual Tailscale endpoint for
`ox host describe` and `ox host providers`; Mock must be absent. Quit cleanly
and disable persisted access afterward.

## Local iOS verification

Follow [setup](../setup/SKILL.md) for simulator ownership, runtimes, assigned ports, and baseline state.
Use the shared `ios-simulator` skill for builds, UI interaction, captures, and diagnostics;
`setup` owns OpenOx scheme/signing/launch configuration. Use task-specific
DerivedData. It avoids build-database locks, not concurrent source-generation races.
A matched tap does not prove a native switch changed: wait for stable frames, use
`idb ui tap X Y --duration 0.25 --udid "$UDID"` for switch controls, and verify AX value and behavior. Resolve coordinates from the current AX tree.
`ci:ios` requires idb, Xcode, an explicitly reserved numbered simulator, and Host
connections already enabled. `--app /absolute/Ox.app` skips building and reuses a
verified artifact; rebuild after source changes or switching worktrees. Install/launch
checks the artifact's bundle identifier. Screenshots use `simctl`, not an idb companion. For browser ingress, `simctl openurl` uses the simulator's selected browser, not necessarily Ox. A temporary macOS CoreSimulator harness can target `SimDevice.launchApplicationWithID:options:error:` with `payload_url` as an **NSURL**, not a string; keep the harness outside Git and distinguish targeted URL-delivery evidence from default-browser eligibility. It never provisions, clones, uninstalls, erases,
changes credentials, or enables Host access.

The bundle comes from `--bundle`, `OX_BUNDLE_ID`, or `apps/ios/Local.xcconfig`.
The default Host uses the selected device's assigned port; VPN ingress can use
`--host ws://<simulator-vpn-address>:9101` for ox-1. `ci:ios --loopback` explicitly
opts a Debug Simulator launch into `127.0.0.1`; it still requires Allow connections,
uses ordinary Host APIs, and is compiled out on physical devices and Release builds.
The opt-in is launch-only; relaunch without it to restore Tailscale-only networking.

The runner builds in evidence-local DerivedData unless `--app` is supplied,
installs/launches with `simctl`, and verifies UI through idb.
This is a Host/conversation smoke with visible UI evidence, not composer/Send interaction coverage.
It creates a temporary Mock conversation, sends scenario `2`, verifies the completed reply
and visible assistant message, then attempts to restore the prior saved conversation.
It only shuts down a simulator it booted. Relaunching can discard an unsaved
temporary conversation: use a dedicated QA target, not personal working state.

Screenshots, build results, conversation snapshots, and failure logs go in a new directory
outside the repository; `--output` selects its parent. PID claims coordinate these
runners only, not manual native-tool use or other agents. `test:agent-ui-ios --device ox-1 --app /absolute/Ox.app` exercises the actual
temporary-conversation Pi path with native Mock already selected. It checks reasoning,
Markdown, native snippet tools, separate worker ownership and drain-before-restart
for Stop followed by queued input, committed SQLite history and process reopen.
It requires an idle conversation, claims the selected simulator, uses no Host transport,
and restores ordinary launch afterward. `OX_DURABLE_TEMPORARY_SESSION=<UUID>`
enables temporary-conversation UI attachment in Debug and Release builds on simulators
and physical devices; it does not enable Host access or adopt persisted Profiles.
Diagnostic RPCs remain restricted to DEBUG Simulator builds. Stopped-process SQLite copies include WAL/SHM
and are diagnostic evidence, not Profile exports or power-loss verification.

Keep Mock focused on model streaming, tool loops, handoffs, and model-visible context. Feature-specific regression setup, assertions, and cleanup belong in E2E runners, not new numbered Mock scenarios. The Mock menu is the source of truth for supported inputs; retired numbers fall back to that menu. Removing a Mock regression does not establish replacement coverage.

Bundled skill boundaries use `bun .agents/skills/test/apps/ios/bundled-skills.ts --device ox-N --host ws://<assigned-host>:<assigned-port> --conversation <seeded-saved-QA-conversation> --temporary-conversation <empty-temporary-QA-conversation>` after installing a fresh build. Seed the saved Mock conversation with `QA bundled skill verification seed. Reply QA only.` before creating the temporary conversation; inspect after creation for its prepared ID. It verifies Pi-derived native schemas, canonical package bytes, references/helpers, discovery/search, mutation denial, old-path aliases, paginated Unicode reads, exact multi-edits and diffs, parallel-edit serialization, an editable run-owned copy with cleanup, and mutations without prior System activation while preserving temporary-conversation restrictions. After relaunch, wait for `ox host describe` to succeed; a successful native launch does not establish Host readiness. Open the saved QA conversation before creating the empty temporary conversation so both are hydrated without discarding the temporary one. For the default delete-approval policy, leave the app on that Profile's Skills screen and pass `--ui-cleanup`; this confirms deletion of only the run-owned copy without widening policy. Mock `72 bundled` covers model-visible loading and System activation; it is not full workflow verification.

`settings.ts` requires an already reachable Host on the selected simulator's assigned port and an idle saved conversation. It exercises language/theme, app-default and conversation-model setters, automatic-model reset, and repository listing/enablement through `ox`, checks validation, no-op results, and hidden compatibility aliases, relaunches the supplied app to verify persistence, and restores the original preferences and saved conversation. VM helper namespace changes do not rename persisted Action identifiers; preserve existing approvals and user-authored helper calls. It does not enable Host access, change credentials, or reset data. Host ingress failures block live verification. For authorized local QA, launch the Debug Simulator app with `OX_HOST_LOOPBACK=1`; never widen physical-device/Release access or bypass approvals to make a test pass.

`local-repository.ts --device ox-N --host <ws-url> --conversation <saved-QA-conversation> --bundle <bundle-id> --domain <qa-draft-domain>` verifies disabled Local mutation refusals against the native Host and byte-identical source, Git, and configuration snapshots. Use enabled Local, an empty run-owned `qa-` web draft, and an idle saved Mock conversation seeded with `QA Local repository enablement regression. Reply QA only.` It restores enablement and writes identical source after reenabling; it creates no drafts or commits. Delete the prepared run-owned draft through the normal UI afterward. This checks runtime safety, not real-model prompting.

`service-icons.ts --device ox-N --host <ws-url> --conversation <saved-QA-conversation> --domain <run-owned-MCP-domain>` serves an attached QA MCP fixture at `http://127.0.0.1:<registryPort>/mcp-favicon-qa` with the matching launch-only `OX_SERVICES_ENDPOINT`. It verifies bundled discovery guidance, small PNGs, ICO frame selection, malformed/unsupported images, candidate fallback, dimension/download limits, and unchanged no-redirect policy for MCP-advertised URLs through actual native loading. It restores the fixture's saved favicon URL; remove the run-owned connection through the UI after the campaign. `--live` additionally contacts Google, httpbingo, and httpbin for explicit HTTPS ICO, redirect success, redirect-limit, unsafe-redirect, and HTTPS-downgrade checks. No provider credentials or website-state changes are required.

`durable-conversation.ts --models` uses native Mock scenario `23` through the actual UI without Host ingress. It verifies deferred switches, pending no-ops, Stop/failure cancellation, and the next queued turn's model, then runs `23 defaults` to verify default selection/reset, invalid arguments, current-conversation isolation, and restoration. It uses the explicit temporary SQLite fixture and restores the normal launch environment; it does not change provider credentials and restores the original new-conversation default. This fixture requires automatic or Mock defaults. Default relaunch checks require the Host-based suite; persisted-conversation model reload is not covered.

`ox-errors.ts` checks the live VM's three-field `code`, `message`, and `recovery` errors across schema validation, filesystem/native bridges, denied System mutations, missing service attachments, serialization, console output, and uncaught failures. It also verifies help, aliases, parallel failures, and successful calls. Use an idle QA conversation and a fresh installed build; it does not change files, settings, policies, or conversation selection.

`image-widget.ts` verifies remote/local image display, zoom-viewer handoff, source
validation, file moves, model-context separation, process reopen, and remote
failure/retry through `ox`, `simctl`, and `idb`. Use a dedicated saved Mock QA conversation seeded with
`0` and a fresh app on the assigned loopback Host. It retains run-owned fixtures and
the conversation for human review; remove them through normal UI when finished. It never
changes approval policies, provider credentials, or website state. Mock accepts
`execute\n<JavaScript>` for runner-supplied tool calls; keep feature fixtures in E2E
rather than numbered scenarios. After seeding, use the prepared saved ID from
`conversation inspect`, not the provisional ID returned by `conversation new`.

`profile-files.ts` uses a saved Mock conversation whose first message starts with `QA filesystem backend verification seed.` and a fresh installed app. It verifies conversation-relative writes, co-located read-only virtual metadata/transcripts, history aliases, explicit transcript search, private paths, checked edits, directory moves retiring old references, same-path live edits, independent copies, current attachment types, empty-directory persistence, and process reopen. It creates and deletes one run-owned conversation to verify transferred-back ownership cleanup and shared-copy survival, then removes its shared fixtures through ordinary conversation approval without changing Action policies. It does not establish hidden predecessor-archive retention, predecessor upgrade, package round trips, real-provider submission, or physical-device power-loss safety. Pass `--profile-folder <active-local-name>` to also verify the public/private split, external create/edit/move/delete/recreate, physical Memory, and writable user skill resources. Original Memory bytes are restored even after failure. File checks use `ox.fs` paths; historical-reference identity retirement is not covered by this runner. A queued send followed by idle is not proof that a Mock tool ran; verify its result or independent filesystem effect, and retain submission/approval evidence when either is absent. VM calls add receipts to the current transcript; compare immutable historical turns, not whole successive transcript snapshots, when verifying history aliases.

Profile Settings → Files presents the native document picker at that Profile's public folder. Verify nested navigation, cancellation/reopen, type-based viewers, and rejection of selections outside that Profile. UIKit can dismiss the picker before delivering its selected URL; exercise the selection-to-viewer handoff rather than accepting dismissal alone. Remote picker controls can be missing from AX; inspect stable screenshots before coordinate interactions. Resolve picker URLs through explicit `/`-prefixed Profile paths so root-level filenames are not mistaken for compatibility references. System search depends on Files indexing and is not established by folder-browsing verification.

`test:demo` checks native preview
presentation and unchanged profile/repository state, not live integrations; use
the `demo` skill for its workflow.

## Evidence

Package-owned `package-check.ts` files verify release artifacts and consumers;
never publish as a test. Model evaluation follows the `evals` skill and exploratory
UI campaigns follow `gym`. Neither replaces live upgrade/auth/service verification.
Committed service/storage replay fixtures are not maintained here. Device-template
CLI E2E checks live in `apps/ios/template-cli.test.ts` and
`apps/ios/template-launch-safety.test.ts`; setup owns their schema,
launcher, and synthetic JSON. Exact predecessor inputs and website-session snapshots
remain private external files. A current logical template does not establish upgrade
compatibility; verify actual predecessor-written storage through normal startup and
second-launch stability.

Report commands, targets, results, limitations, and private evidence paths. State
when real iOS, models, authentication, or services were not exercised. Keep logs,
reports, screenshots, recordings, and predecessor snapshots outside the repository.

---
name: test
description: Run and diagnose OpenOx portable CI, CLI/contract E2E checks, standalone CLI installation checks, and explicit local iOS smoke or demo verification. Use for software correctness and verification evidence; real-model behavior belongs to evals and exploratory user simulation to gym.
---

# Test

`apps/` owns CLI and iOS checks, `contracts/` owns Client-Host and Host-Service
boundary checks, and `scripts/ci.sh` orchestrates portable CI. No agent runtime is
required. Use `evals` for real-model behavior, `gym` for exploratory UI campaigns,
and `demo` for demo capture.

## Choose verification

Run from the repository root, or use `bun run --cwd <checkout>`.

| Need | Command | Read when needed |
| --- | --- | --- |
| Portable CI | `bun run ci` | [Portable verification](references/portable.md) |
| Standalone CLI installation | `bun run ci --standalone-only --out /tmp/ox-cli-artifacts` | [Portable verification](references/portable.md) |
| CLI/contract E2E | `bun run test:e2e` | Discovers this skill's `*.test.ts` files |
| macOS Host | `bun run test:host-macos --app /absolute/OxHost.app --output /tmp/ox-macos-evidence` | Local macOS verification below |
| Log pagination | `bun run test:logs` | Controlled Host fixture |
| Host/conversation iOS smoke | `bun run ci:ios --device ox-1 --loopback` | [iOS verification](references/ios.md) |
| VM integration | `bun run test:vm --device ox-1 --host ws://127.0.0.1:9101` | Fresh QA build; contracts, namespace help, errors, filesystem and Profile switching |
| Native agent UI and reopen | `bun run test:agent-ui-ios --device ox-1 --app /absolute/Ox.app` | [iOS verification](references/ios.md) |
| Native demo previews | `bun run test:demo --device ox-1` | [Demo coverage](references/ios-runners.md#demo-previews) |

Feature runners live in `apps/ios/`. Read the relevant section, then run
`bun .agents/skills/test/apps/ios/<runner>.ts --help` for current arguments.

| Runner | Coverage and preparation |
| --- | --- |
| `bundled-skills.ts` | [Skill boundaries](references/ios-runners.md#bundled-skills) |
| `settings.ts` | [Settings and persistence](references/ios-runners.md#settings) |
| `service-icons.ts` | [Native icon loading](references/ios-runners.md#service-icons) |
| `browser-state.ts` | Synthetic Browser counter-cases; fresh Debug loopback build and idle Mock QA conversation via `--conversation` |
| `durable-conversation.ts --models` | [Queued model selection](references/ios-runners.md#model-selection) |
| `ox-errors.ts` | [Structured VM errors](references/ios-runners.md#structured-errors) |
| `image-embed.ts` | [Image display and viewer](references/ios-runners.md#image-embed) |
| `profile-files.ts` | [Profile filesystem](references/ios-runners.md#profile-files) |

## Run and report

Portable CI needs Bun, Git, and npm; it runs without simulators or credentials.
It verifies static checks, controlled CLI/Host fixtures, package consumers, and
eval definitions. Simulator flows and eval runners are not automatically executed.
A green portable run does not establish live iOS, model, auth, or service coverage.

For iOS, follow [setup](../setup/SKILL.md) for reserved targets, assigned ports,
and baseline state; use `ios-simulator` for builds, UI interaction, and diagnostics.
Read [iOS verification](references/ios.md) before a live run. Use a dedicated QA
target and a fresh build after source changes. Preserve credentials and approval
policies; follow each runner's restoration and cleanup requirements.

Perform E2E verification as needed, using existing runners or temporary workflows.
Add a persistent E2E test case only when the user explicitly requests one;
verification alone does not require codifying a case.

Keep Mock focused on streaming, tool loops, handoffs, and model-visible context.
When adding a requested case, put feature regression setup, assertions, and cleanup
in E2E runners. Use the Mock menu for supported inputs; removing a scenario does
not establish coverage.

Keep runner paths and help flags executable; verify documented commands and
compatibility spellings through real processes before using a live target.
Never publish as a test. Storage compatibility requires actual predecessor-written
data through normal startup and second-launch stability, not a current template.

Keep logs, reports, screenshots, recordings, and predecessor snapshots outside Git.
Report commands, targets, results, coverage limits, and private evidence paths;
state when real iOS, models, authentication, or services were not exercised.

## Provider verification

Exercise installation-specific provider changes through an Ox conversation using
the bundled `evolve` skill's provider workflow. Use the `ox-cli` skill for conversation,
provider-state, and structured-log inspection. Test bundled defaults in an isolated
setup without saved overrides masking them; never delete a user's override to
reset a test because provider deletion also clears credentials.

Distinguish schema validation, discovered model availability, authentication, and
successful inference. Exercise tools or attachments before claiming support;
upload success alone does not prove a model can read an attachment. Obtain
permission for billable inference or uploads. Preserve credentials, drafts,
existing conversations, and the selected model. Report which definitions were
validated, which models were exercised, and which checks remain unperformed.

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

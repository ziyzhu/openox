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
| Log pagination | `bun run test:logs` | Controlled Host fixture |
| Host/conversation iOS smoke | `bun run ci:ios --device ox-1 --loopback` | [iOS verification](references/ios.md) |
| Native agent UI and reopen | `bun run test:agent-ui-ios --device ox-1 --app /absolute/Ox.app` | [iOS verification](references/ios.md) |
| Native demo previews | `bun run test:demo --device ox-1` | [Demo coverage](references/ios-runners.md#demo-previews) |

Feature runners live in `apps/ios/`. Read the relevant section, then run
`bun .agents/skills/test/apps/ios/<runner>.ts --help` for current arguments.

| Runner | Coverage and preparation |
| --- | --- |
| `bundled-skills.ts` | [Skill boundaries](references/ios-runners.md#bundled-skills) |
| `settings.ts` | [Settings and persistence](references/ios-runners.md#settings) |
| `local-repository.ts` | [Disabled Local mutation safety](references/ios-runners.md#local-repository) |
| `service-icons.ts` | [Native icon loading](references/ios-runners.md#service-icons) |
| `durable-conversation.ts --models` | [Queued model selection](references/ios-runners.md#model-selection) |
| `ox-errors.ts` | [Structured VM errors](references/ios-runners.md#structured-errors) |
| `image-widget.ts` | [Image display and viewer](references/ios-runners.md#image-widget) |
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

---
name: evals
description: Run, compare, diagnose, and extend Ox's real-model behavioral evals through ordinary Ox CLI conversations, including answer, tool-use, and independently observed workflow outcomes. Use for repeatable agent-quality measurement; use Ox Gym for exploratory user simulation.
---

# Ox evals

Read [references/suite.md](references/suite.md) before running or modifying evals.
Cases, scoring, comparison, and the external runner live in `scripts/`.
Portable case validation is invoked by the `test` skill's CI command.

Default runs select four read-only smoke cases, one repetition, and a 30000 ms
task limit. Use focused cases during iteration and explicitly select exhaustive
suites for coverage audits. Keep native handoffs and costly mutations out of
routine smoke runs. Smoke does not establish full System workflow coverage.

Use `bun run evals --list --suite all` to inspect the scenario catalog and
`bun run evals --coverage <report>` for observed coverage. Every `ox.*` function
must be mapped to a realistic journey; do not generate per-function variant triples.
Group related operations around one user outcome. System skills require complete
task outcomes, not discovery-only reads. Select a configured
real provider/model with `ox host providers` and an explicit QA Host. Reuse the
user's authorized target and provider choices. Runs consume tokens and execute
real tools; listing, validation, and comparison are local. Mock responses cannot
establish prompt quality.

Follow Simulator Setup ownership and baseline rules in `AGENTS.md`; use `ios-simulator`
and `ox-cli` to prepare a numbered simulator. Build/install the current checkout,
use bundled services and a sanitized QA Profile, and preserve simulator settings.
The runner creates ordinary conversations through this checkout's CLI. Read-only cases,
observers, and probes are temporary; state-changing tasks use saved conversations.
Runs require an outside-repository `--fixture` and named local `--qa-profile`.
Bind independent preconditions, outcomes, preservation, and cleanup to actual QA
state. Unprepared fixtures are blocked, never counted as passing coverage.
Writes require scoped Profile/installation/external opt-in and existing runtime
permissions. It changes the active conversation; never target personal or shared
state. `--allow-choices` answers only declared skill proposal choices. Native
approvals and credentials remain human-controlled; `--human-wait-ms` only waits.
Never reconfigure the simulator or add eval-only app hooks. Controlled environments
use ordinary test websites/API services and synthetic accounts.

For comparisons, capture a baseline, make the focused change, rebuild, then run
the same cases and repetitions on the same model and Profile context. Use
`bun run evals compare <baseline> <candidate>`. Inspect histories and logs, and
repeat suspicious regressions. Keep reports outside the repository. Read answers
against each manual rubric; automatic successes remain unverified until recorded
review. Report model,
coverage, repetitions, failures, and whether manual review occurred. Pass-rate
changes are descriptive, not established statistical improvements.

Turn reproducible failures into sanitized cases with observable assertions.
Validate the source-derived function inventory and all System workflow obligations
after edits. Never label a template, a blocked fixture, or unreviewed evidence as
full live coverage. Expected failures need actual matching failed Action receipts
and independent outcomes; unexpected failures still stop unsafe continuation.
Use real, bounded, read-only tasks by default. Observe resulting state independently,
probe before cleanup without repair, and treat missing evidence as unverified.
Use independent random expected values, never expose answers in fresh-conversation probes,
and stop the cohort on collateral mutations or uncertain cleanup. Do not force tool results or model
responses through eval-only handling. Controlled failure or injection coverage
requires an ordinary test input/service and explicit authorization for its effects.
Do not weaken cases to hide failures or change them during comparisons. Run
`bun run evals --validate --suite all`, `bun run typecheck`, and the CLI E2E checks
after changes. Host changes also need an `xcodebuild` build and live CLI verification.

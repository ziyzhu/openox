---
name: evals
description: Run, compare, diagnose, and extend Ox's real-model behavioral evals through ordinary Ox CLI chats, including answer, tool-use, and independently observed workflow outcomes. Use for repeatable agent-quality measurement; use Ox Gym for exploratory user simulation.
---

# Ox evals

Read [references/suite.md](references/suite.md) before running or modifying evals.
Cases, scoring, comparison, and the external runner live in `scripts/`.
Portable case validation is invoked by the `test` skill's CI command.

Use `bun run evals --list --suite all` to inspect coverage. Select a configured
real provider/model with `ox host providers` and an explicit QA Host. Reuse the
user's authorized target and provider choices. Runs consume tokens and execute
real tools; listing, validation, and comparison are local. Mock responses cannot
establish prompt quality.

Follow Simulator Setup ownership and baseline rules in `AGENTS.md`; use `sim-cli`
and `ox-cli` to prepare a numbered simulator. Build/install the current checkout,
use bundled services and a sanitized QA Profile, and preserve simulator settings.
The runner creates ordinary chats through this checkout's CLI. Read-only cases,
observers, and probes are temporary; state-changing tasks use saved chats.
Workflows require `--allow-profile-writes --qa-profile <local-QA-name>` and existing
creation/cleanup permissions. It changes the active chat; never target personal
or shared state. It never responds to
approvals, imports credentials, reconfigures the simulator, or adds eval-only app
hooks. No repository server is needed.

For comparisons, capture a baseline, make the focused change, rebuild, then run
the same cases and repetitions on the same model and Profile context. Use
`bun run evals compare <baseline> <candidate>`. Inspect histories and logs, and
repeat suspicious regressions. Keep reports outside the repository. Read answers
against each manual rubric; automatic passes do not score it. Report model,
coverage, repetitions, failures, and whether manual review occurred. Pass-rate
changes are descriptive, not established statistical improvements.

Turn reproducible failures into sanitized cases with observable assertions.
Use real, bounded, read-only tasks by default. Observe resulting state independently,
probe before cleanup without repair, and treat missing evidence as unverified.
Use independent random expected values, never expose answers in fresh-chat probes,
and stop the cohort on collateral mutations or uncertain cleanup. Do not force tool results or model
responses through eval-only handling. Controlled failure or injection coverage
requires an ordinary test input/service and explicit authorization for its effects.
Do not weaken cases to hide failures or change them during comparisons. Run
`bun run evals --validate --suite all`, `bun run typecheck`, and the CLI E2E checks
after changes. Host changes also need a `sim` build and live CLI verification.

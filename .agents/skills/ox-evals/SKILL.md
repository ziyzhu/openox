---
name: ox-evals
description: Run, compare, diagnose, and extend Ox's real-model behavioral evals, including system-prompt and tool-decision regressions. Use for repeatable agent-quality measurement; use Ox Gym for exploratory user simulation and service replay for live service correctness.
---

# Ox evals

The suite and its contract live in [evals/README.md](../../../evals/README.md).
Read it before running or modifying evals. Cases, fixtures, scoring, and the runner
belong in `evals/`; keep this skill focused on the workflow.

Use `bun run evals --list --suite all` to inspect coverage. Select a configured
real provider/model with `ox agent list` and an explicit simulator Host. Reuse the
user's authorized target and provider choices. Running the suite invokes that
provider and consumes tokens; listing, validation, comparison, and scoring tests
are local. Mock responses cannot establish prompt quality.

Prepare the numbered iOS 26 QA simulator with the sim-cli and ox-cli workflows.
Rebuild and install the current checkout, use bundled services and an empty chat
in a sanitized QA Profile, and preserve simulator settings. No service repository
server is needed. The runner copies prompt and tool definitions into isolated
in-memory agents and uses fixture-backed tools; it does not run generated code or
make external service changes.

For a prompt comparison, capture a baseline, make the focused change, rebuild,
then run the same cases and repetitions against the same model and Profile
context. Use `bun run evals compare <baseline> <candidate>` and inspect individual
regressions, context/model changes, and errors. Keep reports outside the repository.
Read final answers and traces against each case's manual rubric; automatic passes
do not score that rubric. Report the selected model, case coverage, repetitions,
failures, and whether manual review occurred. Do not present tiny pass-rate changes
as statistically established improvements.

Turn a reproducible failure into a sanitized case with observable assertions.
Keep tool fixtures constrained and distinguish tool-decision coverage from full
execution. Do not weaken a case to hide a failure or change cases during a prompt
comparison. After changes, run `bun run evals --validate --suite all`,
`bun test evals`, and `bun run typecheck`. Changes to the simulator Host also need
a `sim` build and live verification of `agents.evaluate`.

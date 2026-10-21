---
name: evals
description: Run, compare, diagnose, and extend real-model behavioral evals using the production agent loop and stateful ox function stubs. Native VM correctness belongs to integration tests.
---

# Ox evals

Read [references/suite.md](references/suite.md) before running or changing evals.
Cases live in `cases/`, the runner and scoring in `scripts/`, and the local agent
loop, function contracts and isolated stubs in `packages/agent/evals`.

Run the real model with the production prompts and Pi agent loop. Stub `ox.*`
results and state, never model replies. No simulator, live Host, native approval,
external effect or personal Profile is used. Select an explicit supported provider
and model; provider credentials come from standard environment variables. Never
copy credentials into cases or reports. Controlled model replies are only for
tests of the runner, not quality measurements.

Each case is one self-contained file: stubs, the user task, and deterministic
checks over actual receipts, resulting state and the final answer. A low score is
data, not a runner failure. Check outcomes from stub state and receipts, never
from the model's claims. Never put an expected answer in the task. Stub results
must be realistic and contract-valid; every call validates its input and output
against the exported native contracts, and unconfigured calls fail explicitly.
Model JavaScript executes in a bounded child realm without provider credentials,
filesystem or network APIs; only the declared stub dispatch is exposed.

When changing prompts or guidance, add or update a case that targets the changed
behavior, including a counter-case when the change could be gamed by always or
never doing something. Compare the same model, cases and limits, with enough
repetitions to see flakiness. Describe pass-rate differences without claiming
statistical improvements or native platform correctness. Keep reports outside Git.

Run `bun run evals --validate`, `bun run typecheck`,
`bun test packages/agent/test/evals.test.ts`, and `bun run test:e2e` after edits.
Use `bun run test:vm --device ox-N --host <ws-url>` separately against a fresh QA
build for real VM contracts, namespace help, error handling, filesystem access and
Profile switching. Refresh the exported contracts only after reviewing actual API
changes; do not weaken stubs or checks to conceal regressions.

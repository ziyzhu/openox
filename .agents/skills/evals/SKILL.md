---
name: evals
description: Run, compare, diagnose, and extend real-model behavioral evals using the production agent loop and stateful ox function stubs. Native VM correctness belongs to integration tests.
---

# Ox evals

Read [references/suite.md](references/suite.md) before running or changing evals.
The scenario catalog, evidence checks and reporting live in `scripts/`; the local
agent loop, function contracts and isolated stubs live in `packages/agent/evals`.

Run the real model with the production prompts and Pi agent loop. Stub `ox.*`
results and state, never model replies. No simulator, live Host, native approval,
external effect or personal Profile is used. Select an explicit supported provider
and model; provider credentials come from standard environment variables. Never
copy credentials into fixtures or reports. Controlled model replies are only for
integration tests of the runner, not quality measurements.

Default smoke runs cover Profile, providers, repositories and schedules once with
a 30000 ms task limit. Use `--list --suite all` for the exhaustive scenario catalog.
Every function must map to a realistic journey. A declared scenario or valid schema
is not passing evidence. Unprepared scenarios remain blocked. Preserve independent
outcome and preservation assertions, expected error receipts, skill resource reads,
fresh probes and cleanup checks. Never supply expected answers to probe prompts.

Use stateful fixtures with realistic contract-valid outputs, meaningful error cases,
and scoped transitions. Every call validates its input and output against the
exported native contracts. Unconfigured calls fail explicitly. File operations use
the production filesystem logic with isolated in-memory storage. Keep each case and
repetition independent; only the task, its probe and cleanup share fixture state.
Model JavaScript executes in a bounded child realm without provider credentials,
filesystem or network APIs; only the declared stub dispatch is exposed.

Keep fixtures and reports outside Git. Compare the same model, fixtures, prompts,
contracts and limits. Read answers against the manual rubric; automatic successes
remain unverified until recorded review. Reports identify stubbed execution and
cannot be compared with legacy live-eval reports. Describe pass-rate differences
without claiming statistical improvements or native platform correctness.

Run `bun run evals --validate --suite all`, `bun run typecheck`,
`bun test packages/agent/test/evals.test.ts`, and `bun run test:e2e` after edits.
Use `bun run test:vm --device ox-N --host <ws-url>` separately against a fresh QA
build for real VM contracts, namespace help, error handling, filesystem access and
Profile switching. Refresh the exported contracts only after reviewing actual API
changes; do not weaken fixtures or assertions to conceal regressions.

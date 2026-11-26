# Benchmarking

Use controlled benchmarks for task completion, latency and cost comparisons. This is an opt-in measurement workflow under test, not a correctness suite or a default CI gate. Gym discovers issues through simulated user interaction; benchmarks measure a predeclared comparison. Use existing build, setup and ox-cli guidance for their owning operations.

**Define the experiment.** Declare the question, two arms, representative cases, repetitions, required correctness checks, deadline, timing boundary and primary metric before inspecting outcomes. Declare which effects and real-provider spending the current request authorizes; a saved plan is not authorization for future paid runs. Prefer at least four repetitions per case for equal first-arm counts. Three repetitions leave a 2:1 split, not perfect balance. Choose counts before running; never stop early because results look favorable.

**Freeze and prepare.** Build both arms from immutable source snapshots outside the shared checkout. Include dirty and untracked source, exact ablations, dependency/toolchain versions and artifact hashes. Record provider/model/reasoning, cache policy, device/OS, prompts and fixtures. Reuse build tooling and fixed simulator reservations; do not duplicate their lifecycle code. Keep credentials in supported stores, never in plans, command arguments or evidence. Preserve initial Profile, conversation, appearance and boot state. Preflight actual exposed APIs and selected model settings. Verify native transport settings rather than trusting picker metadata alone. Later changes to main are not covered by the frozen experiment.

**Plan.** Save a definition outside the checkout, then run:

```sh
bun .agents/skills/test/benchmark/plan.ts /tmp/experiment.json
```

The command creates an owned temporary directory containing plan.json and prints its SHA-256. It only plans; it does not build apps, claim devices or call providers. It rotates case position and alternates arm order within each case. Do not shuffle or edit its schedule after observing results. It supports exactly two arms; more elaborate designs need an explicitly reviewed experiment, not ad hoc extensions.

Definition shape, with real frozen identities and hashes substituted:

```json
{
  "question": "Does configuration B reduce verified task completion time?",
  "arms": [
    { "id": "baseline", "source": "commit + dirty-manifest + ablation evidence", "artifactSha256": "<64 hex characters>" },
    { "id": "candidate", "source": "same snapshot, candidate changes recorded", "artifactSha256": "<64 hex characters>" }
  ],
  "cases": [{ "id": "catalog", "prompt": "Identical task text for both arms" }],
  "repetitions": 4,
  "timeoutMs": 300000,
  "timingBoundary": "Immediately before submission through terminal idle; 500 ms polling",
  "requiredChecks": ["correctInvocation", "correctAnswer", "freshPage", "alternateInput"],
  "environment": {
    "provider": "explicit configured identifier",
    "model": "explicit discovered identifier",
    "reasoning": "medium",
    "device": "reserved device, OS and assigned Profile endpoint",
    "caches": "Not cleared; document any prewarming"
  }
}
```

**Execute.** Keep experiment-specific execution and assertions in the owned evidence directory, using existing CLI/build/fixture utilities. Do not promote the old Catalog/Search/Reports experiment or its feature-ablation scripts into a permanent suite. There is intentionally no generic device runner or automatic approval policy here. Run trials sequentially without competing QA load; otherwise mark performance evidence contaminated. Verify the installed arm's hash, isolate starting state, use the scheduled prompt, start the declared clock and retain normal in-task errors, repairs and authorized approvals. On deadline or interruption, stop the actual conversation as well as the driver process. Never blanket-approve prompts or replay uncertain mutations. Missing terminal evidence is not success. Record a setup failure before submission separately from an in-task failure; do not time setup as task execution or replace failed attempts with retries. Each additional attempt needs a predeclared extension or a separate campaign.

**Verify independently.** Stop timing at the declared terminal boundary, then check the delivered artifact on fresh state and a different input. For Evolve, require production skill activation, a validated persisted service, actual invocation data and a correct final answer. Inspect qualified invocation names and the native succeeded payload rather than assuming CLI wrappers are the result. Check parameterization, source persistence and actual feature use separately from feature availability. Keep independent checks and screenshots outside timing and label them. Capture website-dependent visuals while the fixture server is live. Never preserve hidden model reasoning.

**Record.** Write results.json next to the unmodified plan.json. Its planSha256 must match the exact plan bytes. Append records durably after each trial; never overwrite failures with later attempts. Use the schedule index to identify the case/arm/repetition. A verified record requires every declared check to be true and a positive elapsedMs within timeoutMs. Statuses are verified, task_failed, provider_failed, output_limit, deadline, blocked, harness_failed and setup_failed. Only setup_failed may use null elapsedMs. Unexecuted indices remain unrun, not fabricated failures or successes.

```json
{
  "planSha256": "<printed plan SHA-256>",
  "results": [{
    "index": 1,
    "status": "verified",
    "elapsedMs": 104882,
    "checks": { "correctInvocation": true, "correctAnswer": true, "freshPage": true, "alternateInput": true },
    "metrics": { "modelMs": 99000, "toolWallMs": 4800, "roundTrips": 16 },
    "featureUsed": false,
    "evidence": "trial-01/request.json, trace.json, native logs and postcheck.json"
  }],
  "cleanup": { "status": "completed", "evidence": "restored-state.json and released claim" }
}
```

Metrics are optional observed numbers: modelMs, toolWallMs, roundTrips, inputTokens, cachedInputTokens, outputTokens and costUSD. Missing values mean unknown, not zero. Do not invent subscription prices or costs from token counts. Set featureUsed only when actual adoption was checked. Cleanup statuses are completed, incomplete or not_attempted; record failed cleanup rather than silently claiming restoration.

**Report and restore.** On completion, failure or interruption, restore saved state, close owned pages, stop owned fixtures, follow setup's boot-state cleanup rules and release only owned reservations. Do not erase simulators or delete user data. Do not automatically promote or publish services. Preserve raw evidence under the owned temporary directory, then run:

```sh
bun .agents/skills/test/benchmark/report.ts /path/to/owned/plan.json
```

The reporter writes summary.json and report.md beside the plan. It rejects mismatched plans, duplicate/unknown trials and unverified success claims. Report success counts with all recorded outcomes in the denominator, planned versus unrun coverage, successful-only medians, per-case results, paired deltas, arm order, observed metrics, feature adoption, cleanup and limitations. Latency comparisons on successful pairs are conditional on both arms succeeding; failed pairs remain visible but do not become artificial deadline-valued completion times. The task-stratified bootstrap is exploratory and does not account for provider temporal correlation or generalize beyond sampled cases. Review evidence before claiming a performance benefit. Historical campaign comparisons are descriptive unless the experimental design actually isolates the change. Keep prior campaigns immutable and separate. No automatic pass/fail speed threshold is imposed.

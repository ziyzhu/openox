# Session protocol

Each user-driver subagent owns one session at a time. Its assignment must include the session ID and seed, persona, intent and success condition, exact prompt or prompt sequence, verified Ox provider target, simulator and endpoints, concrete setup and action policy, initial state, allowed effects, time, model-call and step budgets, and evidence directory. Do not delegate unless `materializationStatus` and `providerVerification` are ready and `executionAuthorized` is true.

## Isolation

- Use one fixed numbered QA simulator and its matching ports.
- Run sessions assigned to the same simulator in separate waves; never let two active drivers share a simulator.
- Keep session evidence in the assigned `/tmp/ox-gym.*/sessions/<id>` directory.
- Do not inspect other drivers' trajectories or campaign conclusions.
- Do not modify repository source during a simulation.
- Treat existing unrelated worktree changes as user-owned.

## Preflight outside the interaction timer

Confirm the simulator exists and is available, repository health is green, the intended app build is installed and launched, the Host is discoverable, and the required Mock or real provider is exposed. Establish theme, app language, keyboard, permissions, chat state, and safe fixtures before declaring the starting UI ready.

If preflight cannot establish the assigned state or authorization, return `blocked` with the exact boundary. Do not silently substitute a different provider, model, locale, or simulator.

## Observe, decide, act

Repeat until the goal, abandonment condition, failure, or guardrail is reached:

1. Observe the visible screen through an accessibility description and screenshot when visual context matters.
2. Recall the persona, intent, prior actions, outcomes, and remaining budget.
3. Choose one plausible user action or terminate. Use concise observable rationale such as `response still has no visible progress; low-patience persona abandons`.
4. Execute through `sim`, preferring identifiers and labels over coordinates.
5. Record the action, target, timestamps, immediate outcome, relevant UI state, and errors.
6. Feed an execution failure back into session memory once so the user can recover intelligently. Do not blindly repeat an unchanged action.

Use `ox chat inspect` and structured logs to verify state or diagnose boundaries, not to bypass UI actions under test. Direct `ox agent run` or the LLM benchmark may provide supporting isolation evidence after the user-visible session.

## Time and action budgets

The 120-second wall clock begins when the assigned starting UI is ready:

- At 90 seconds, stop optional exploration and pursue the shortest plausible completion or abandonment decision.
- At 105 seconds, preserve the current state and prepare a terminal result.
- At 120 seconds, cancel active generation or tools where possible and stop. The coordinator must interrupt an overrun.

Retries and recovery remain inside the same clock and model-call cap. Default to at most 20 user actions, three provider calls, and one retry. A timeout is an outcome and potential finding, not permission to extend the run.

## Evidence

Capture continuously enough that a timeout remains diagnosable:

- Initial and terminal accessibility state with matching screenshots.
- Screenshots or photos at meaningful state transitions and failures, including before and after state when the difference matters.
- A short screen recording when motion, streaming, gesture handling, transient UI, background/return, cancellation, or timing cannot be established by still images. Start immediately before the relevant sequence and stop immediately after it; do not record an entire campaign by default.
- Exact prompts and visible responses.
- User actions and outcomes with monotonic elapsed time.
- The smallest relevant structured Ox log interval, including `AgentLatency.summary`, correlation identifiers, warnings, and errors when present.
- Chat state and selected model verification.
- Resource samples when assigned.

Record every artifact in `result.json` with its kind, relative path, capture time or monotonic offset, and what it proves. Correlate videos and screenshots with action timestamps and log intervals. Treat visual evidence and logs as complementary: the visual artifact establishes user impact, while the log explains timing or cause.

Do not photograph or record credential entry, authentication codes, provider keys, or other reusable secrets. If an unrelated secret appears unexpectedly, stop capture and exclude that artifact from the report. Keep all raw evidence inside the assigned temporary directory.

Do not run heavy traces during ordinary discovery. When the coordinator requests reproduction, record one deterministic interaction with `sim trace` and avoid concurrent diagnostics. `sim stats` covers the app process but not separate WebKit helpers; state that limitation when it matters.

## Session result

Write `result.json` before returning:

```json
{
  "version": 1,
  "sessionID": "session-001",
  "seed": 123,
  "startedAt": "ISO-8601",
  "finishedAt": "ISO-8601",
  "elapsedMs": 120000,
  "outcome": "completed|abandoned|failed|blocked|timedOut|guardrailStopped",
  "providerTarget": "client:model",
  "persona": {},
  "intent": {},
  "environment": {},
  "actions": [],
  "metrics": {},
  "observations": [],
  "candidateIssues": [],
  "evidence": [
    {
      "kind": "screenshot|photo|video|accessibility|structuredLog|resourceSample",
      "path": "screenshots/terminal.png",
      "capturedAt": "ISO-8601",
      "elapsedMs": 42000,
      "proves": "The response remained visible after background return"
    }
  ],
  "cleanup": { "attempted": true, "complete": true, "detail": "" }
}
```

Return the outcome, strongest observations, candidate issues, and result path to the coordinator. Never return hidden reasoning.

## Concurrency and performance

Parallelize bounded functional discovery only while host memory and swap remain healthy. Stop adding drivers when simulator contention causes SpringBoard instability, provider throttling, or distorted responsiveness.

Confirm performance findings sequentially on one owned simulator, with the same persona, intent, prompt, starting state, provider, app build, and network context. Report distributions only from comparable trials.

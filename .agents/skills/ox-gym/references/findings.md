# Findings and reporting

Judge observable user experience, not whether a trajectory resembles an imagined ideal. Separate observed facts from inference and distinguish Ox behavior from driver, provider, service, simulator, host-resource, and network failures.

## Detection signals

Use several independent signals where possible:

- Explicit success conditions and UI invariants.
- Differential results across builds, providers, models, themes, languages, or devices.
- Structured warning and error logs.
- Missing or anomalous latency milestones.
- Accessibility, screenshot or photo, and short screen-recording inspection.
- Repeated actions, excessive repairs, confusing approvals, or abandonment.
- Metamorphic checks such as equivalent rephrasing, background and return, relaunch, retry, or model switch.
- Sequential reproduction of performance or reliability anomalies.

## Taxonomy

Classify candidate issues as functional, UX, visual, accessibility, performance, reliability, provider behavior, provider neutrality, conversation state, persistence, tool or service integration, localization or input, privacy or logging, resource pressure, or observability gap.

Assign likely ownership as product, provider, service, environment, driver, unknown, or needs human confirmation. Do not turn a provider limitation or synthetic-user mistake into an Ox defect.

## Finding contract

Every accepted finding includes:

```yaml
id: OXGYM-001
title: Concise statement of the observed problem
category: performance
severity: high
confidence: medium
scope: provider-specific
persona: impatient-cautious-novice
intent: multi-turn-planning
observed: Useful content first became visible after 8.4 seconds
expected: Visible progress or useful content within the configured threshold
impact: Low-patience user abandoned before completion
reproduction: 2/3 comparable sessions
likelyOwner: provider
evidence:
  - sessions/session-002/result.json
  - sessions/session-002/screenshots/terminal.png
  - sessions/session-002/recordings/cancel-retry.mov
  - sessions/session-002/logs/agent-latency.json
recommendation: Reproduce sequentially and inspect provider preparation latency
```

Use severity for user impact and confidence for evidentiary strength. A severe single synthetic observation can remain low-confidence. Never fabricate thresholds after seeing a result; use an existing baseline, a request-specific threshold, or report the metric descriptively.

Prefer evidence that triangulates the observation: a screenshot or short video for the user-visible effect, accessibility state for semantic UI, and a narrow structured-log interval for timing or cause. Do not require every format when one artifact is sufficient, and do not treat a log-only anomaly as confirmed user impact without visible or behavioral evidence.

## Campaign report

Write `findings.md` with:

1. Executive summary and counts by terminal outcome.
2. Prioritized accepted findings.
3. Mock versus real-provider observations.
4. Performance and resource summary, including contention limitations.
5. Dimension coverage: configured, eligible, attempted, completed, unavailable, excluded, and not covered.
6. Candidate issues rejected or awaiting human confirmation.
7. Timed-out, blocked, and incomplete sessions.
8. Cleanup state and evidence locations.
9. Limitations and recommended next actions.

For each reproducible product defect, recommend the smallest existing deterministic suite that should own regression coverage. Do not leave Ox Gym as the only protection for a stable failure.

Update `campaign.json` with terminal session summaries and report-relative evidence paths. Keep raw private logs inside the owned temporary directory and quote only narrow credential-free excerpts.

Aggregate repeated evidence without hiding individual variation. For sufficiently comparable repeated runs, report pass rate and p50/p90 latency. Do not present confidence intervals or statistical significance without enough independent observations and a stated method.

If no finding survives triage, write `No issues were observed in the covered scenarios`, followed by the exact coverage and limitations. Never claim that Ox has no issues.

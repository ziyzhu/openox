---
name: gym
description: Simulate diverse persona-conditioned users through Ox's live iOS interface with Mock or bounded real model providers, using seeded subagent sessions to surface functional, UX, visual, accessibility, performance, reliability, provider, state, privacy, localization, and observability issues. Use for exploratory, comparative, stress, or replay simulation campaigns; not for unit-only model evaluation or direct service authoring.
---

# Ox Gym

Exercise Ox as a user would, preserve observable evidence, and return prioritized findings. Treat synthetic-user results as exploratory until they are calibrated against real user behavior.

## Read the relevant guidance

- Read [references/dimensions.md](references/dimensions.md) when planning personas, intents, environments, coverage, or randomized selection.
- Read [references/session-protocol.md](references/session-protocol.md) before driving simulators or delegating sessions.
- Read [references/findings.md](references/findings.md) before judging sessions or writing the report.

Also use the agent-independent `ios-simulator` and `ox-cli` skills. Consult installed native-tool and Ox help instead of guessing commands or flags.

## Relationship to deterministic tests

Ox Gym does not replace build checks or the three maintained suites: protocol validation,
storage backward compatibility and real-provider evals. It explores realistic combinations
and surfaces evidence fixed checks may miss. Add a persistent case only when explicitly
requested and within one of those three suites.

Do not use Gym as an archive for deterministic regression runners. Protocol checks
belong to the protocol suite; out-of-scope runners should be removed, not relocated here.

## Roles

Keep one coordinator responsible for the campaign, simulator allocation, guardrails, reproduction, and final findings. When subagents are available, assign one isolated user-driver subagent to each active session. Give a driver only its session manifest, relevant skill instructions, owned simulator, evidence directory, and operational constraints; do not give it suspected bugs or conclusions from other sessions.

The user driver is distinct from the Ox model provider under test. Hold the driver model and instructions stable when comparing Ox providers or builds.

## Modes

- `explore`: coverage-guided randomized sessions against one configuration.
- `compare`: paired personas and intents across builds, providers, or models.
- `stress`: emphasize slow, long, interrupted, failing, multilingual, and resource-heavy experiences.
- `replay`: resimulate a recorded manifest or repeat its recorded UI actions.

Default to `explore`. Use a recorded seed for every campaign and derived seed for every session. Randomize conditions, not meaningless taps.

## Workflow

1. Resolve mode, session count, providers, comparison targets, authorized effects, and available numbered QA simulators. Default to six sessions when the request gives no count; session count is not simulator count. Run them sequentially on one reserved simulator unless the user requests parallel execution. Do not make paid real-provider calls unless the current request authorizes them and their count is bounded.
2. Discover configured models and eligible dimension values, then generate the session plan and its owned `/tmp/ox-gym.*` directory with `scripts/plan-run.ts`. Pass supported additional axes with `--dimension`, provider and model identifiers only, and never credentials. Pass `--authorize-real` only when the current request authorizes real-provider calls. Use `--previous` only when the user explicitly supplies prior ephemeral manifests for cumulative coverage.
3. Materialize every selected dimension into concrete setup, prompts, fixtures, and actions before delegation. Verify the provider and language, then set `materializationStatus`, `providerVerification`, and `executionAuthorized` to ready values. Never delegate a planner-only session. Remove or mark a value unavailable when it cannot actually be exercised. Keep manifests, logs, screenshots, short screen recordings, traces, and reports inside the planner-created directory. Do not write campaign artifacts into the repository or a Profile.
4. Follow [setup](../setup/SKILL.md) for simulator reservation, runtime, and common-state rules. Claim only fixed `ox-1` through `ox-5` simulators. Give every concurrent process its own numbered simulator and matching service and debug ports from `.agents/skills/setup/scripts/qa-config.ts`; use its repository port only for explicit repository installation or sync verification.
5. Before interaction timing begins, build with `xcodebuild` and install through `simctl`, launch Ox with bundled services, discover its Host, and establish the session's initial simulator appearance, language, model, and state. Reuse a verified prebuilt app where appropriate, but rebuild and reinstall after switching worktrees.
6. Run sessions sequentially on the reserved simulator by default. Only use multiple simulators when parallel execution is requested; bound concurrency to the requested level and available resources, keeping one coordinator slot available. Have each driver follow the session protocol and return structured evidence.
7. Aggregate candidate issues. Reproduce performance regressions and ambiguous high-severity findings sequentially on one owned simulator without competing QA activity. Shut down only simulators owned by this campaign; coordinate with other agents or defer clean performance measurements when their devices remain active. Never interrupt another agent's simulator. Parallel simulator or provider contention invalidates clean performance comparisons.
8. On completion, failure, or interruption, follow setup's boot-state cleanup rules: shut down devices this campaign booted unless ownership was handed off, leave previously booted devices running, and release campaign-owned claims. Write `findings.md` and update `campaign.json` inside the owned temporary directory. Report cleanup state, session outcomes, strongest findings, coverage gaps, limitations, and exact report path.

## Non-negotiable boundaries

- Each user interaction session has a hard 120-second wall-clock limit after its starting UI is ready. Retries do not reset it. The coordinator must interrupt an overrun.
- Drive the visible UI with `idb` on the explicit reserved UDID. Use accessibility identifiers and the current accessibility tree before coordinates. Do not replace an interaction under test with Host debug commands.
- Use `ox` for Host discovery, conversation inspection, structured logs, VM or service inspection, and supporting model-isolation evidence.
- Default to read-only user goals. External mutations require explicit authorization and narrow cleanup. Never supply blanket approval flags.
- Never read, print, log, or pass provider credentials through command-line arguments. Existing configured credentials remain inside Ox's supported boundaries.
- Capture observable actions, state, concise decision summaries, and outcomes. Do not request or preserve hidden model reasoning.
- Use screenshots or photos for state, short screen recordings for motion or interaction sequences, and bounded structured logs for causal and timing evidence. Capture only the smallest artifact that proves the observation.
- Detect repeated identical actions, cap steps and retries, propagate execution failures back to the driver once for informed recovery, and terminate gracefully when a guardrail fires.
- Photos, recordings, and logs are private user-owned diagnostics. Keep them under the owned temporary directory, retain only relevant material, and never capture or include reusable secrets.
- A successful task may still yield UX or performance findings. No observed issue means only that the covered sessions produced no issue.

## Completion

Finish when all planned sessions are terminal or interrupted, cleanup has been attempted, candidate findings have been triaged, and the temporary report is usable. If setup fails, still produce a report that names the exact boundary, affected coverage, evidence available, and cleanup state.

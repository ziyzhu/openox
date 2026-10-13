# Ox evals

The default `smoke` selection runs four read-only conversations once: Profile,
providers, repositories, and schedules. Each has a 30000 ms task limit; diagnostic
calls add bounded overhead. This is a small regression signal, not full coverage.
Use `--case` for a focused change and select the exhaustive suites explicitly.
No live duration claim is established until measured against the chosen model.

The replacement catalog owns three exhaustive suites: `functions`, `workflows`, and `safety`.
Related functions are grouped into realistic journeys with one user outcome.
Focused failure and boundary cases cover important risks rather than repeating
three variants for every function. The catalog is capped at 86 scenarios.
All five System skills have task scenarios with independent outcome, preservation,
and applicable precondition, probe, and cleanup obligations. Reading a skill is
required but never establishes workflow completion. The old 11 cases are retired.
Required authoring references are also independently read and matched to actual
model tool output; installed skill/resource text is included in comparison context.

`scripts/cases/` is the executable scenario catalog. `scripts/coverage.ts` checks
its function inventory against native catalogs and its skills against the System
catalog. A new function without a declared journey fails portable validation.
Every successful journey binding requires actual successful receipts for each
declared function, alongside independent outcome and preservation assertions.
Scenario coverage is a specification, not evidence that a model passed it.

```sh
bun run evals --list --suite all
bun run evals --template --qa-profile EvalQA --output /tmp/ox-smoke-fixture.json
bun run evals --validate --suite all
bun run evals --list --suite workflows --json
bun run evals --template --case app-profile-success --qa-profile EvalQA --output /tmp/ox-reader-fixture.json
bun run evals --validate --suite all --fixture /tmp/ox-reader-fixture.json
bun run evals --fixture /tmp/ox-reader-fixture.json --host <ws-url> --provider <id> --model <id> --qa-profile EvalQA --case app-profile-success --output /tmp/ox-reader-report.json
bun run evals --coverage /tmp/ox-reader-report.json
```

The runner drives this checkout's ordinary Ox CLI conversations. No eval RPC,
alternate agent, forced tool result, Mock quality score, or eval-only runtime hook
is used. CLI E2E fixtures verify the runner rather than real-model quality.

## Prepare QA bindings

Use an exclusively owned numbered QA simulator or dedicated QA Host, a freshly
built checkout, bundled services, and a sanitized named local QA Profile. Read
`ios-simulator` and `ox-cli` for setup. Inspect `ox host list` and
`ox --host <ws-url> host providers --json`; select an explicit real model.
The runner neither provisions the Host nor imports credentials or changes policies.
It refuses active work/pending prompts but changes the selected conversation and
may discard an outgoing temporary conversation. Never target personal state.

Fixtures are version 1 JSON outside Git with `qaProfile` and `cases` keyed by
scenario ID. `--template` produces ready bindings for simple read-only function
successes and Profile skill creation/fresh-use, with independent random probe
inputs. Other scenarios get incomplete scaffolds. Incomplete scaffolds are
rejected; they must not be counted as implemented live coverage. Use `--list
--json` to inspect each scenario's exact task and evidence obligations.

Each prepared binding contains:

- `context`: synthetic task inputs and environment details, never expected answers,
  credentials, or production state. Prepare the actual website/API/service/files
  through ordinary interfaces before running. The runner does not silently seed
  or repair them. Use isolated accounts and sandbox payment, not real purchases.
- `observations`: named read-only VM readers, explicit conversation snapshots, or
  CLI provider/conversation lists. VM readers use `{kind: "vm", name, args}`;
  conversation readers use `{kind: "conversation", id}` (`{{task}}` binds the task);
  CLI readers use `{kind: "cli", command: "providers" | "conversations"}`.
  `{kind: "skill", name}` independently parses complete canonical skill metadata
  and instructions. Optional `phases` limit readers to before/after/cleanup, for
  example reading a newly created package only after creation.
- `assertions`: `{evidence, phase, observation, path, operator, expected?}`. `path`
  is an array of literal object keys/array indexes; `[]` selects the whole result.
  Phases are `before`, `after`, `probe`, and `cleanup`. Operators are exact JSON
  `equals`, string/array/object-subset `includes`, baseline `unchanged`, and
  `absent` under an observed parent. Missing parents never prove absence.
- `actions`: actual native receipt expectations with `name`, `outcome`
  (`succeeded`/`failed`), `minimum`, optional `maximum`, and optional exact argument
  subset. Bound uncertain submissions and writes to one effect. Failed results
  require matching expected native failure evidence, never a blanket exception.
  Every state-changing allowed Action needs an explicit expectation; cleanup
  Actions can have minimum zero in the task with run-owned argument constraints.
- `allowedActions`: exact scoped names, including necessary discovery/read,
  presentation, execution, and cleanup. This is an audit, not a runtime permission
  grant. Read-only scenarios cannot authorize writes or external effects.
- `cleanup`: a separate ordinary conversation prompt removing only run-owned
  effects after outcome observation and probing. Existing state must not be
  repaired or deleted. Include baseline restoration assertions for every changed
  surface, not just fixture disappearance.
- `probeContext` for fresh probes: only skill name and variable inputs, never the
  expected answer or original creation context. Generate independent random test
  values and calculate expected answers outside the agent.

Every binding requires an explicit independent QA precondition. Bind every named
scenario evidence obligation to the correct phase. `outcome` and `preserved` must
use independent observations, not task text or tool-source strings. `condition`
establishes the actual failure/boundary before submission. `preserved` and `cleanup`
use baseline equality. `probe` evaluates the fresh snapshot. Extra answer assertions
may inspect `task`/`probe` snapshots (including normalized `answer`), but cannot
replace independent state evidence.

For generated IDs, observer arguments and conversation IDs may use
`{"$receipt":"ox.conversation.start","path":["id"]}` in after/cleanup phases.
Action argument expectations accept the same reference. Cleanup prompts can use
`{{receipt:ox.conversation.start:id}}`; scalar values are JSON-quoted. Resolution
requires exactly one successful complete native receipt, never assistant prose.
Ambiguous, missing, or truncated references fail closed. Cleanup runs as a later
turn in the original task conversation so attachments, working files, model
selection, and page-local handles keep their actual owner; its checks inspect
only the newly submitted cleanup turn. Probe conversations remain fresh.

Observers reject truncated inventories/text, dropped capture records, missing
values, and oversized observations. Prepare bounded fixtures or scoped readers;
never omit an affected surface to make observation pass. Observe complete provider
definitions, unrelated configuration, Local files/history/source selection,
schedules, memory/soul/skills, file ownership, remote effect ledgers, and child
conversation outcomes as applicable. Secret observers use metadata only.
Native UI/media, HTML interactions, visual appearance, and human handoff outcomes
need actual native/UI evidence reviewed against the rubric; file creation alone
does not verify rendering or interaction. These requirements cannot be established
by a controlled CLI transport or a receipt alone.

## Execute and review

State-changing cases use saved conversations. Opt in separately with
`--allow-profile-writes`, `--allow-installation-writes`, and
`--allow-external-effects` according to both the scenario and its allowed Actions.
Installation changes include shared provider/settings state across Profiles.
Opt-in never bypasses runtime gates or expands fixture scope.

`--allow-choices` answers only a scenario-declared skill proposal choice with
exact matching options. It never answers native Action approvals or credential
entry. Other checkpoints are blocked by default. `--human-wait-ms <ms>` permits
bounded waiting while the human completes a native gate in QA Ox; the runner
prints the conversation and checkpoint, never enters secrets or approves it.
Deliberate web authoring and memory approval use declared later user turns.
Unexpected choices remain human-controlled.

`--timeout` defaults to 30000 ms for smoke and 120000 ms for exhaustive suites,
maximum 300000, bounding the task and its
observations/probe. Cleanup has a separate 30000 ms budget; stop/snapshot/log CLI
calls have bounded diagnostic deadlines. Inputs are never resubmitted after
uncertain transport. Missing receipts, collateral effects, failed observation,
unsettled work, or uncertain cleanup stop the cohort and preserve evidence for
the owner. Cleanup never repairs results before probing.

Reports are version 4, owner-only JSON at new outside-repository paths. They
include model/catalog, build/revision/dirty state, authorization, fixture hash,
planned repetitions, context/case hashes, histories, actual receipts, choices,
before/after/probe/cleanup evidence, checks, rubrics, and paginated Host logs.
Host logs are run-window diagnostics; correlate IDs and never score unrelated
errors. Reports and fixtures can contain private context; keep them out of Git.

Automatic successes are `unverified`, not passed workflow coverage. Read the
history, independent observations, and applicable native/UI evidence against the
rubric, then record an explicit review in a new report:

```sh
bun run evals --review /tmp/ox-reader-report.json --case app-profile-success --repetition 1 --decision pass --note "Reviewed answer against the independently observed Profile and checked preservation." --output /tmp/ox-reader-reviewed.json
bun run evals --coverage /tmp/ox-reader-reviewed.json
bun run evals compare /tmp/ox-baseline-reviewed.json /tmp/ox-candidate-reviewed.json
```

Review cannot override failed/missing automatic checks. Coverage distinguishes
planned, blocked, unverified, failed, error, and passed; partial repetitions never
establish a passing cohort. Exit codes are 0 for all reviewed passes, 1 for failure
or error, and 2 for blocked/unverified/incomplete coverage. Listing/validation are
local and cost no model tokens.

Comparisons reject earlier report formats and mark changed cases/fixtures,
models, authorization/limits, incomplete repetitions, errors, blocked or
unreviewed evidence as not comparable. Keep the same rebuilt app, QA environment,
model/reasoning, fixtures, inputs, and repetitions. Context changes are reported;
pass-rate differences are descriptive, not established statistical improvements.

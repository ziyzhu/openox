# Ox evals

Run real models through Ox's production `Agent` loop with the production system
prompt and tool schemas taken from an empty simulator chat. Each case gets a new
in-memory agent; multiple prompts in one case share only that agent's history.
Tools use ordered fixtures. Generated JavaScript is inspected, never executed.
This measures model behavior and loop recovery, not live service correctness,
UI behavior, or the complete Chat lifecycle and its dynamic turn-state hooks.

## Run

Prepare a numbered iOS 26 QA simulator using the normal `sim` workflow. Build and
install the current checkout, launch with its matching debug port, use bundled
services, configure the provider through the normal secure bootstrap or app UI,
and open a fresh empty chat. The runner does not install, erase, or reconfigure
simulators, change settings, or import credentials.

```sh
bun run evals --list --suite all
ox discover
ox --host ws://127.0.0.1:9105 agent list --json
bun run evals --host ws://127.0.0.1:9105 --provider <id> --model <id>
bun run evals --host ws://127.0.0.1:9105 --provider <id> --model <id> --suite all --repeat 3 --output /tmp/ox-candidate.json
bun run evals compare /tmp/ox-baseline.json /tmp/ox-candidate.json
```

`quick` is the default suite. `--case search-recovery` selects a single case.
`--timeout` bounds each case on the Host, including all user prompts and tool
rounds. `--max-turns` bounds model turns across the entire case. The Host cancels
timed-out agents. Provider and transport errors stop the run instead of overlapping a retry
with a potentially active request. Each report records the app's reported
version/build, checkout revision and dirty status, model catalog entry,
prompt/tool hash, full messages with usage, duration, fixture errors, scoring
results, and the manual rubric. A checkout revision alone does not prove which
binary is installed: rebuild before every comparison.

Reports are written after each attempt with owner-only permissions to a new path
outside the repository. They contain the template chat's effective prompt, which
may include Profile context. Use a dedicated sanitized QA Profile; do not commit
reports. Baseline and candidate runs should use the same Profile context,
provider/model, reasoning settings, repetitions, and case definitions. Comparison
flags changes to model and prompt/tool context, and labels changed cases, missing
attempts, or provider/transport errors as not comparable. Pass-rate changes are descriptive,
not statistical significance. Inspect individual traces and repeat suspicious
regressions before changing a prompt.

## Cases and scoring

Cases live in `cases/index.ts` and are TypeScript data checked by the repository
typecheck. Each includes user prompts, ordered tool-result fixtures, automatic
rules, and a manual rubric. `bun run evals --validate --suite all` validates the
catalog without contacting a provider. Real runs reject the Mock provider.

Fixtures must name an existing tool and constrain its generated source. Unexpected,
mismatched, or unused fixtures fail the case. `isError` deliberately returns an
error to test recovery; `terminate` stops at a tool decision, as in the migrated
protocol smoke case. These are responses at the `execute` boundary, not simulations
of every JavaScript operation. Source substring matching is a routing constraint,
not proof that code is correct. AST checks verify direct calls and syntax but do
not execute code, follow aliases, or prove argument semantics. Use service replays
and simulator QA to verify real execution.

Automatic checks cover exact output constraints, required/forbidden answer facts,
and direct function-call counts. Exact wording is appropriate only when the user
request explicitly requires it. Manual rubrics remain unscored: an automatic pass
is not a claim that a human reviewed answer quality. Cases should contain fixed,
synthetic information and judge observable outcomes. Add failures found during
Ox Gym or real use after sanitizing them. Keep cases stable when comparing prompts;
do not weaken assertions merely to obtain a green result.

The former `test:llm` entry point is replaced by `evals`. Its single execute call,
JavaScript syntax, web search, result printing, and no-`ox.help` checks are covered
by `web-tool-decision`. Select a configured provider/model explicitly and run the
same cases on additional providers when coverage across wire protocols matters.
Service replay, storage migration, and other software tests remain separate.

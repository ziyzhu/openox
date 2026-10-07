# Ox evals

The external runner invokes this checkout's `ox` CLI to drive ordinary chats.
Models, tools, services, permissions, and runtime hooks behave as they do in Ox.
There is no eval RPC, fixture tool executor, alternate agent, or native turn limit.

## Run

Prepare an exclusively owned numbered QA simulator using the normal `sim`
workflow. Rebuild/install the checkout, use bundled services and a sanitized QA
Profile, configure a real provider, and enable normal Host access. The runner
requires an explicit Host and provider/model; it does not provision or enable them.
For local Debug Simulator access, launch with `--env OX_HOST_LOOPBACK=1` and its
assigned `OX_DEBUG_ENDPOINT` port, with Allow connections already enabled. Use the
explicit `ws://127.0.0.1:<port>` Host; physical-device/Release access stays Tailscale-only.
It refuses an active busy chat or pending prompt but changes the active chat and
can discard an outgoing temporary chat. Never run against personal working state.

```sh
bun run evals --list --suite all
ox host list
ox --host <ws-url> host providers --json
bun run evals --host <ws-url> --provider <id> --model <id>
bun run evals --host <ws-url> --provider <id> --model <id> --suite tasks --repeat 3 --output /tmp/ox-tasks.json
bun run evals --host <ws-url> --provider <id> --model <id> --suite all --allow-profile-writes --qa-profile EvalQA --repeat 3 --output /tmp/ox-candidate.json
bun run evals compare /tmp/ox-baseline.json /tmp/ox-candidate.json
```

`quick` is the default: four text-only cases. `tasks` contains public web search
and five guidance discovery cases. `workflows` contains skill creation and a
fresh-chat usage probe. `--case` selects one case; `--repeat` defaults to one.
Workflows, including `--suite all`, require explicit write opt-in and an already
active, named local QA Profile. Existing policies must allow `ox.skill.create`
and `ox.skill.delete`; the runner neither changes policies nor answers approvals.
Task chats are saved and retained for diagnosis; observer/probe chats are temporary.
Cleanup removes only the uniquely named, run-owned skill, not unrelated state.

`--timeout` defaults to 120000 ms and bounds setup, initial/final observations,
task prompts, and probes, not provider turn count. Stop/snapshot/log collection
has separate bounded CLI deadlines; cleanup and its observations share a further
30000 ms deadline. After uncertain submission the runner requests ordinary
`chat stop` without resubmission. Missing or truncated evidence and transport/
provider/cleanup errors stop the suite. Approval/input requests fail and are
stopped, never automatically answered. Unsettled chats or violated monitored
invariants block further attempts. Observers never repair results before probing.

Reports are version 3, owner-only JSON at new paths outside the repository.
They contain app identity, revision/dirty state, authorization, provider catalog,
planned cohorts, initial context hashes, chat histories with usage, native Action receipts, before/
after/cleanup observations, probe evidence, durations, checks, and manual rubrics.
They can contain private Profile context; never commit them. Host logs are paginated
run-window diagnostics, not necessarily attributable to the task: correlate IDs,
and never score unrelated log errors. A checkout revision does not establish
which binary is installed; rebuild before comparisons.

Keep Profile context, model/reasoning settings, cases, and limits stable.
Comparison rejects earlier report formats, flags prompt/tool context changes,
and marks changed model/limits/cases, incomplete planned cohorts, or errors not comparable.
Cases skipped in both reports still appear as not comparable, never silently vanish.
Pass-rate changes are descriptive, not established statistical improvements.

## Cases and grading

Cases live in `scripts/cases/index.ts`; validate with
`bun run evals --validate --suite all`. Real runs reject Mock. Common checks require
completed turns, settled chats, complete model responses, declared tools, valid
snippet syntax, and successful matching tool results. Generated source is not
proof that a nested operation ran: tool behavior uses native Action receipts.

Guidance cases independently read the expected guide through `ox vm call`, require
a successful model-initiated read and a matching 256-character excerpt in actual
tool output, and compare monitored state before/after. Summary quality remains a
manual rubric; these cases cover discovery, not the full guided workflow.
Web search requires a successful search Action and the expected URL in tool output
and the final answer; relevance and citation quality remain manual.

Skill creation requires exact independently parsed metadata/instructions, no
service dependencies or extra resources, and a successful authorized skill write.
A fresh chat receives only the skill name, reads the saved skill, and must return
its independent random token. State and Action audits detect collateral work;
cleanup is independently re-observed. Monitored surfaces are Profile identity,
provider catalog, default model, language/theme, policies, artifact inventory,
memory/soul, and mounted skill text files. This is not a complete Profile export,
credential-content audit, binary-resource comparison, or process-restart test.
Truncated inventories, unsupported files, missing fields, or more than 1 MiB of
observed memory/soul/skill text fail closed. Extend observations for new workflows.

Manual rubrics are stored, not automatically scored. Old synthetic grounding,
forced retry/failure, injected web-result, and decision-only smoke coverage is
retired, not represented as equivalent live coverage. Add controlled inputs and
probes through ordinary APIs/services, never eval-only runtime hooks.

Portable CLI E2E checks use a controlled Host transport. They establish runner
behavior, not real-model quality or live iOS correctness. Ox Gym and simulator
UI QA remain separate.

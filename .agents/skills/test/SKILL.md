---
name: test
description: "Verify storage backward compatibility, check agent behavior on a QA Host, and plan opt-in controlled benchmarks for task completion, latency and cost."
---

# Test

Storage backward compatibility is the maintained test suite. `bun run test` runs
offline build-tool and shipped-bundle checks. `bun run lint` owns static/type
validation; `bun run build` owns generated-artifact consistency, packaging and
compilation. Exploratory UI verification belongs to Gym.

## Backward compatibility

Read [storage compatibility](references/storage-compatibility.md) and the canonical
[storage map](references/storage.md) for persisted-storage changes. Case definitions
and the supported X-to-Y matrix live in `compatibility/`; private templates,
predecessor artifacts, snapshots and evidence stay outside Git. App release versions,
exact build revisions and storage milestones are separate identities: record all three.

Require actual predecessor-written data, normal startup migration, representative
ordinary writes, complete data preservation and a stable second launch. A current
serializer, clean install or template-validator pass cannot substitute for an upgrade.
Missing predecessor artifacts block verification. Downgrade testing is opt-in.

## Targeted agent verification

Use [Ox CLI](../ox-cli/SKILL.md) against an explicit reserved QA Host and a disposable
Profile. Pick the provider and exact model ID from `ox host providers`. Use Mock
for deterministic Host checks; real inference requires explicit authorization and
a bounded run. Stage only synthetic data. For example, verify that an answer comes
from a file rather than from the prompt:

```sh
ox --host "$QA_HOST" conversation new --temporary --provider "$PROVIDER" --model "$MODEL" --json
```

Set `CONVERSATION` to the returned `conversationId`.

```sh
ox --host "$QA_HOST" --conversation "$CONVERSATION" vm call ox.fs.write \
  --args '{"purpose":"Seed QA fixture","path":"notes.txt","content":"Meeting code: MAPLE-739"}'
ox --host "$QA_HOST" --conversation "$CONVERSATION" conversation send \
  'Read notes.txt and tell me the meeting code.' --json
ox --host "$QA_HOST" --conversation "$CONVERSATION" conversation inspect --messages --json
ox --host "$QA_HOST" --conversation "$CONVERSATION" conversation logs --json
```

Require a completed turn, the expected answer, and a successful `AgentCall.end`
for `ox.fs.read` scoped to that turn. A CLI run exercises the real Host; it does not
inject tool responses or score a baseline. Use controlled fixture services for
scripted responses, never real inboxes or accounts as stand-ins.

## Benchmarking

Use [benchmarking](references/benchmarking.md) for controlled completion-rate, latency
and cost comparisons. It provides a counterbalanced plan generator and evidence-based
reporter; experiment-specific device execution reuses existing infrastructure. This
is not a correctness suite, a default CI gate, or authorization to spend on real
providers. Keep plans, task-specific drivers and raw evidence outside the checkout.

## Run and report

Reproduce an issue before fixing it. Add persistent cases only when explicitly
requested and only within the storage compatibility suite. Do not add unit tests.

Use reserved QA devices and explicit targets. Preserve credentials, approval policies
and personal data. Require confirmation for destructive replay; do not uninstall or
erase to simulate an upgrade. Build affected native targets before native verification.

Report commands, component/build identities, results, coverage limits and private
evidence paths. Distinguish pass, fail and blocked. Never publish as a test or imply
credential-free CI exercises live models, authentication, native UI or storage upgrades.

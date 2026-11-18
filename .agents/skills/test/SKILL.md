---
name: test
description: "Coordinate storage backward compatibility and real-provider evals. Plan and report opt-in controlled benchmarks for task completion, latency and cost."
---

# Test

Maintain two suites. Do not create a general unit, UI, smoke, or miscellaneous
regression suite. `bun run test` runs offline build-tool checks, shipped-bundle
checks, and child-process execution isolation. `bun run lint` owns static/type
validation; `bun run build` owns generated-artifact consistency, packaging and
compilation. Exploratory UI verification belongs to Gym.

| Suite | Entry point | Evidence |
| --- | --- | --- |
| Backward compatibility | [Storage compatibility](references/storage-compatibility.md) | Actual X-written snapshots opened by Y, preserved data and second-launch stability |
| Evals | `bun run evals --help`; [evals](../evals/SKILL.md) | Real provider/model, production prompts, tool receipts and basic prompting results |

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

## Benchmarking

Use [benchmarking](references/benchmarking.md) for controlled completion-rate, latency
and cost comparisons. It provides a counterbalanced plan generator and evidence-based
reporter; experiment-specific device execution reuses existing infrastructure. This
is not a correctness suite, a default CI gate, or authorization to spend on real
providers. Keep plans, task-specific drivers and raw evidence outside the checkout.

## Run and report

Reproduce an issue before fixing it. Add persistent cases only when explicitly
requested and only within the maintained suites. Do not add unit tests.

Use reserved QA devices and explicit targets. Preserve credentials, approval policies
and personal data. Require confirmation for destructive replay; do not uninstall or
erase to simulate an upgrade. Build affected native targets before native verification.

Report commands, component/build identities, results, coverage limits and private
evidence paths. Distinguish pass, fail and blocked. Never publish as a test or imply
credential-free CI exercises live models, authentication, native UI or storage upgrades.

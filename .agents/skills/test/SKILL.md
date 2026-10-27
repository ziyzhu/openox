---
name: test
description: "Validate versioned protocol boundaries and predecessor-to-current storage upgrades. Coordinate the three maintained suites: protocol validation, backward compatibility, and real-provider evals."
---

# Test

Maintain exactly three suites. Do not create a general unit, UI, smoke, or miscellaneous
regression suite. Static validation, type checks, generated-artifact consistency,
packaging and compilation belong to build. Exploratory UI verification belongs to gym.

| Suite | Entry point | Evidence |
| --- | --- | --- |
| Protocol validation | `bun run test:protocol` | Component versions, accepted/rejected requests, mutation and reconnect behavior |
| Backward compatibility | [Storage compatibility](references/storage-compatibility.md) | Actual X-written snapshots opened by Y, preserved data and second-launch stability |
| Evals | `bun run evals --help`; [evals](../evals/SKILL.md) | Real provider/model, production prompts, tool receipts and basic prompting results |

## Protocol validation

Cases live in `protocol/client-host/` and `protocol/host-services/`. Exercise public
boundaries with real CLI processes and controlled Host/service fixtures. Cover
supported versions, unsupported and unversioned peers, malformed responses,
reconnection and negotiation, and rejection before mutation. Never replay a
submitted mutation after transport or Host errors. Static schema consistency is
build coverage, not runtime protocol coverage.

Record component versions. Same-revision fixtures do not prove older components
work: use pinned predecessor contracts or artifacts when claiming cross-version
compatibility. Log pagination and legacy response compatibility run with the portable
protocol suite. Native function and structured-error contracts live in `protocol/native/`;
use `bun .agents/skills/test/protocol/native/vm.ts --help` or
`bun .agents/skills/test/protocol/native/ox-errors.ts --help` against a fresh QA app.
These native checks require an explicit reserved simulator and assigned Host endpoint;
portable fixtures alone do not establish native implementation conformance.

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

## Run and report

Reproduce an issue before fixing it. Add persistent cases only when explicitly
requested and only within these three suites. Put setup, observable assertions and
cleanup in the owning runner, not feature-specific Mock scenarios. Do not add unit tests.

Use reserved QA devices and explicit targets. Preserve credentials, approval policies
and personal data. Require confirmation for destructive replay; do not uninstall or
erase to simulate an upgrade. Build affected native targets before native verification.

Report commands, component/build identities, results, coverage limits and private
evidence paths. Distinguish pass, fail and blocked. Never publish as a test or imply
credential-free CI exercises live models, authentication, native UI or storage upgrades.

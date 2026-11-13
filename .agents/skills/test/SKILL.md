---
name: test
description: "Validate versioned protocol boundaries and predecessor-to-current storage upgrades. Coordinate the three maintained suites: protocol validation, backward compatibility, and real-provider evals."
---

# Test

Maintain exactly three suites. Do not create a general unit, UI, smoke, or miscellaneous
regression suite. `bun run test` runs the existing offline build-tool checks and portable
protocol cases; it does not run storage upgrades or real-provider evals. `bun run lint`
owns static/type validation; `bun run build` owns generated-artifact consistency,
packaging and compilation. Exploratory UI verification belongs to gym.

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
Website service cases live in `protocol/web/` and run with
`bun run test:web --device ox-N [--app <Ox.app>] [--case <name>]` against a Debug
Simulator build. Fixture sites model bundled service archetypes: server-rendered
two-page login, client-rendered same-page login with streamed `conversation`
generation, in-page GraphQL with CSRF, a same-site accounts provider hop, and a
cross-site sign-in widget nested in iframes. They are served over HTTPS on
`*.localhost` with a CA trusted on that simulator only; Debug Simulator builds allow
those hosts. The runner applies a run-owned template Profile, serves fixture services
through the development repository, drives turns through Mock `execute` scripts,
answers only expected prompts, deletes saved logins it created, and records
screenshots and accessibility trees for failures. Assert with service results, fresh
`listSessions` and fixture-server counters such as password submissions and CSRF
rejections. Point `login` `baseUrl` at the sign-in route: the automatic step loop
continues only while each step retrieves the saved login. Web content inside the
handoff is reachable only through `idb ui describe-point`; open the full-screen
handoff before typing into it. When a bundled service introduces a new site or login
shape, add a fixture for it.

For filesystem audits, round-trip ordinary files in the default conversation working
directory, include mixed text/binary searches and exact-limit results, and reconstruct
continued reads to detect missing or duplicate content.
For API/MCP error audits, inspect the fields caught by conversation JavaScript,
including errors crossing an API handler's nested runtime. Use isolated fixtures
and server-side dispatch counts to verify that denied calls never dispatch and
uncertain writes are not replayed; preserve and restore approval policies.
For MCP binary transfers, use nonprivate synthetic images and verify both native
image/resource decoding and schema-declared file-reference expansion. Check that
polls and model-visible results contain metadata, not encoded bytes; exercise
combined-size limits, denied reads, session scope and symlink escapes.

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

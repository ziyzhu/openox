# Ox agent — Pi Durable integration

This implements a host-neutral Session and an opt-in native-chat rollout from
[`assets/PI_DURABLE.md`](../../assets/PI_DURABLE.md), **not the finished production replacement**.
Normal startup and persisted chats retain their existing agent and storage paths.
DEBUG Simulator callers can attach an idle **temporary** chat to a cache Session;
persisted chats are refused to prevent two transcript authorities.

## Entry points and boundaries

- `@openox/agent`: native-free, instance-owned Session core. Inject SQLite, pi-ai
  models, artifact I/O (or explicit blob-fixture allocation), permissions,
  reporting and committed-event delivery. Importing it installs no native shims.
- `@openox/agent/ios`: explicit JavaScriptCore setup, native model/tool adaptation
  and Swift command transport. Application UUID routing stays in this adapter.
- `@openox/agent/chat-bindings`: optional UUID lookup rebuilt from Pi records;
  the core also runs unbound Pi conversations.
- `@openox/agent/storage-diagnostics`: **published Pi Durable storage conformance
  and benchmarks only**, with the native SQLite adapter. No mock model, native
  effect receipts, custom file/codec checks, or fault-injection commands.

`openOxAgentSession(options)` owns its Harness, registry, Profile files and
observers. Use Pi's conversation creation/configuration through `session.harness`.
`run`, `observe` and `abort` accept Profile-qualified conversation references;
numeric Pi IDs remain a low-level compatibility path. `close()` drains file work
and joins Pi/observers before disposal without committing cancellation outcomes.
Hosts must enforce one owner per database.

Pi conversation records are authoritative. `ChatBindings` reconstructs a disposable
lookup; `ox.chat` v1 contains only the external chat UUID. Provider/extension names
remain unchanged. A Session is not a chat, and internal conversations need not
have an application binding or visible presentation.

## Layout

- `src/core/session.ts`: Harness lifecycle and committed-event delivery.
- `src/core/committed-partial.ts`: detached presentation values from committed changes.
- `src/core/profile-files.ts`, `artifacts.ts`: document-backed Profile text and
  immutable native artifact references. SQL blobs remain explicitly fixture-only.
- `src/core/conversations.ts`: scoped references/cursors, presentation/favorite/read
  documents and full fork-aware history, separate from active model context.
- `src/core/profile-env.ts`, `file-tools.ts`: filesystem policy and authorization;
  shell execution and unsupported operations fail explicitly.
- `src/adapters/ios/`: JSC setup, bridge, native model/tool and artifact adapters.
- `src/sqlite.ts`: transaction exclusion across awaits, handle expiry and rollback.
- `src/storage-check.ts`: upstream `createStorageConformance` cases.
- `src/storage-benchmark.ts`: upstream seeds, workloads and expected results.
- `apps/ios/Ox/Host/Durable/`: native SQLite/JSC, message codec, artifact owner and
  capability adapter. Swift retains credentials, permissions and snippet VMs.
- `apps/ios/Ox/Host/RPC/DebugDurable{Storage,Chat}.swift`: bounded DEBUG admission.

Pi Durable, pi-ai and Chord are pinned to **1.0.0**. Audit upgrades and rerun
upstream checks and actual-chat E2E before changing these dependencies.

## Build and verify

```sh
bun install --frozen-lockfile
bun run build:agent
bun run test:agent
bun run typecheck
```

The existing portable integration/conformance and bundle-boundary tests remain.
Application acceptance uses actual-chat E2E, not a parallel mock proof harness.
The custom proof, conversion/package experiments and agent-overhead benchmark
have been removed. `installOxProfile` installs normalized drafts into fresh,
dormant physical-backend stores and returns qualified conversation mappings.
Native decoding and staging stay in `StorageMigrator`. This is the start of the
production cutover, not activation: normal readers/writers, publication, lifecycle
and export/import still require replacement before the legacy path can be removed.

Audited IIFEs are generated into ignored `apps/ios/Ox/Resources/PiDurable.bundle/`:

- `harness.js`: actual iOS adapter/core, no storage diagnostics or faux provider.
- `harness-storage.js`: upstream storage diagnostics, no Ox Session/chat adapter.

The build removes the obsolete `harness-proof.js` artifact. The manifest records
package versions, sizes and SHA-256; upstream licensing is included. Builds reject
Node adapters, external runtime imports, shell tools and provider SDKs. Normal
startup does not initialize a Pi context or open these cache databases.

The old standalone fixture replay and benchmark runners have been removed.
Actual UI acceptance lives in the test skill:

```sh
bun run test:agent-ui-ios --device ox-1 --app /absolute/Ox.app
```

Use a freshly built DEBUG app and an idle chat with native Mock selected. The
runner verifies reasoning, Markdown, native snippet tools, Stop, committed Pi
history and reopening the cache Session across process restart. It uses the
explicit `OX_DURABLE_TEMPORARY_SESSION=<UUID>` UI opt-in, not Host RPC, and clears
the opt-in afterward. This launch flag also supports Release builds on physical
devices; diagnostic RPCs remain DEBUG Simulator-only. Diagnostic stopped-process SQLite copies are not exports,
graceful-close or physical-device power-loss evidence. This does not convert
persisted chats or implement production Profile adoption.

Use `sim` and `ox` for application verification;
check simulator ownership, pass `--device` explicitly and keep evidence outside
the repository. Host access requires native **Allow connections** opt-in and
approved Tailscale ingress. Temporary-chat diagnostics use private cache storage,
not real Profile conversion or production activation.

## Upstream storage benchmarks

Native diagnostics retain the **published Pi Durable 1.0.0 workloads**.

`debug.durable.storage` admits only `storageConformance` and `storageBenchmark`.
The benchmark imports `seedStorageBenchmark`, `STORAGE_READ_BENCHMARKS`,
`seedStorageWriteBenchmark`, `STORAGE_WRITE_BENCHMARKS`, published scales and the
record-count helper. Every upstream expected result and SQLite integrity is checked.
No Harness, scheduler, model request, receipt table or Ox binary store is involved.

- All **12 read workloads** share one fresh seeded dataset, one discarded warmup
  sweep and 1–20 retained sweeps (default five).
- Each of **three write workloads** has one discarded warmup and retained samples.
  Every sample uses a fresh runtime/database and upstream 100-entry baseline.
- `timing`, `1k` and `10k` select upstream read scales; write baseline is independent.
- Native `DispatchTime` measures operation wall time including JSC/bridge/backend
  work. Setup/close and integrity checks are outside operation timings.
- SQLite uses WAL, `synchronous=FULL`, foreign keys enabled; upstream Node defaults
  to NORMAL, so these are not automatic apples-to-apples comparisons.
- Fresh fixtures live at `Caches/PiDurableDiagnostics/<action>/<uuid>/` and are
  removed after SQLite close on success/error. Concurrent diagnostics and stale
  fixture reuse are refused. Crashes may leave purgeable caches, never adopted.
- Whole-app gauges are not isolated Pi backend memory measurements.

Earlier upstream results on `ox-1`, iOS 26.0, SQLite 3.51.0 passed all three scales
with three retained samples. These pre-cleanup DEBUG Simulator measurements are
historical diagnostics, not current-build, device or production performance claims.

## Storage and remaining gates

Temporary-chat cache paths remain `PiDurableProof/Native/<uuid>/session.sqlite`
and `PiDurableProof/NativeFiles/<uuid>/state.sqlite` plus `artifacts/`. They may
contain user messages, provider metadata and native diagnostics: treat them as
private on-device scratch data. They contain no credentials/website sessions and
never participate in Profile backup, sync or export. Old experiment caches are
left untouched and never adopted.

Physical artifacts are write-once, digest-checked files owned by one native scope.
Publication precedes Pi metadata commits; interrupted publication can leave orphan
bytes. Logical removal retains historical metadata/bytes. Automatic reclamation,
filename reuse and artifact edits are refused. Memory/soul/skills remain documents;
text is bounded at 200 KiB, binary at 32 MiB. Conversation documents and file
metadata checkpoint bounded delta tails. Read-only `/chats` projections come from
Pi, never a second disk transcript. See the [storage map](../../.agents/skills/migrate/references/storage.md).

Normal persisted chats still use the Swift legacy path. Before replacing it:

- Integrate real Profile conversion and upstream version compatibility through
  `StorageMigrator`; preserve recoverable originals and reject future formats.
- Implement consistent export/import with dormant imported-work policy.
- Complete committed-snapshot UI restoration, native approvals, Session leases,
  steering/follow-ups, compaction, media, services/subagents and provider parity.
- Verify recovery and lifecycle through actual application E2E, including supported
  devices/OS versions, OS termination and large-artifact/memory workloads.

Apple: [JSContext](https://developer.apple.com/documentation/javascriptcore/jscontext),
[JSVirtualMachine](https://developer.apple.com/documentation/javascriptcore/jsvirtualmachine),
[DispatchTime](https://developer.apple.com/documentation/dispatch/dispatchtime/uptimenanoseconds).

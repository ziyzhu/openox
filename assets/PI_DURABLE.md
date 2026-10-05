# Pi Durable integration plan

## Status and goal

This is the agreed architectural direction. The host-neutral Session, opt-in
native temporary-chat adapter, physical artifacts and qualified conversation
projections are implemented. Custom mock proofs, effect receipts, fault injection,
codec/file fixtures, conversion/package experiments and the agent-overhead benchmark
have been removed. Only published Pi Durable storage conformance and benchmarks
remain in a separate diagnostics bundle; application acceptance uses actual-chat E2E.
Production activation, real-Profile conversion/export/import and full replacement
remain unimplemented. Earlier native evidence below is historical, not a pass of
this cleanup. Native RPC verification requires approved Tailscale ingress; do not
weaken transport checks or treat loopback discovery as verification. See
[`packages/agent/README.md`](../packages/agent/README.md) for current commands and gates.

Actual UI acceptance is available through `bun run test:agent-ui-ios --device ox-1
--app /absolute/Ox.app`. An explicit DEBUG Simulator launch UUID attaches only idle
temporary chats to the physical-backend cache; preparation failure never falls back
to the Swift loop. The replay uses native Mock, reasoning/Markdown, native snippet
tools, Stop and process reopen with full retained Pi history. It does not use Host
RPC, change credentials, convert Profiles, or establish power-loss durability.

Use Pi Durable as Ox's sole agent harness through a host-neutral `@openox/agent` integration package. Swift remains the native iOS host adapter; other hosts reuse the shared Ox agent behavior with their own adapters. The agreed production storage unit is a local Profile folder:

```text
<Profile>/
├── profile.json
├── state.sqlite
└── artifacts/
    └── <file name>
```

`profile.json` is the authoritative top-level manifest: stable Profile identity, creation date and overall format/migration milestone. `state.sqlite` owns execution, conversation history and application documents, not a competing copy of manifest fields. `artifacts/` owns ordinary text and binary artifact/attachment files, referenced by Profile-relative paths. Together they compose one Profile store; SQLite is not a duplicate authority for artifact bytes. Keep a virtual filesystem for agent access. SQLite's WAL/SHM sidecars and private incomplete-write staging are implementation details, not additional content authorities.

This supersedes the earlier all-content-in-SQLite proposal. It is a target design, not the current implementation: temporary-chat caches still use `session.sqlite`, `ox_blobs`/`ox_blob_chunks`, and UUID bindings. Do not rename or adopt those caches as production Profiles implicitly.

Profiles use export/import, not live synchronization or external in-place editing. Pi Durable is experimental; pin the adopted package versions and verify upgrades before shipping them.

## Architecture

```text
SwiftUI / Ox Client
        |
Ox Host
        |
iOS adapter — Swift bridge + dedicated JavaScriptCore runtime
        |
@openox/agent — shared Ox Session and application semantics
        |
Pi Durable Harness — one storage Session per open Profile
        |
        +-- Conversations, submissions, and durable tasks
        +-- Profile/application documents in state.sqlite
        +-- Profile-relative artifact files through the native storage adapter
        +-- Model adapter -> Swift providers
        +-- Tools -> Ox services and native capabilities
        +-- Execution environment -> virtual filesystem
```

A Pi storage Session contains many conversations. It is not one chat. In the production target, an Ox chat is a presentation of one Pi conversation, not a separate persisted entity, registry, or transcript. Conversations without Ox presentation state, such as internal roots/subagents, need not appear in the chat list.

Pi conversation IDs are database-local. Application references use the owning Profile identity plus Pi conversation ID; an unqualified numeric ID is not globally unique. `StorageMigrator` converts old chat UUID references. The current `ox.chat` v1 `{ chatID }` binding remains necessary for the temporary-chat adapter until the application identity transition is verified; it is not the production identity model.

Pi owns execution and transcript state. Swift renders projections of committed state and executes native capabilities; it does not maintain a second independently mutable agent loop or transcript.

## Ownership boundaries

The native ownership rows below describe iOS. Other host adapters fulfill the equivalent responsibilities without introducing another agent loop. Shared Ox behavior belongs in `@openox/agent`, not in a particular native bridge.

| Responsibility | Planned owner |
| --- | --- |
| Model/tool loop, input queues, steering, follow-ups | Pi Durable |
| Retries, compaction, task ownership, restart recovery | Pi Durable |
| Transcripts, committed progress, usage | Pi Durable |
| Subagent behavior | Small Ox extension using Pi conversations and tasks |
| Model networking, discovery, credentials, OAuth | Swift providers and native credential services |
| Tool permissions, approvals, device and website operations | Swift capability boundaries |
| Profile manifest/discovery | Native Profile storage; compatibility through StorageMigrator |
| SQLite connection and transaction implementation | Native storage adapter |
| Profile context/settings outside the manifest | Pi documents where their semantics fit |
| Text/binary artifact contents | Native files under the owning Profile's artifacts/ directory |
| UI, previews, notifications, iOS execution leases | Swift |

Pi does not supply a built-in subagent tool. It supplies the durable primitives used to implement one. Preserve Ox's desired subagent policy explicitly rather than assuming the example policy matches it.

Replace the equivalent orchestration in `apps/ios/Ox/Host/Agent/Agent.swift`, `Legacy/AgentRunner.swift`, `Legacy/AgentCompactor.swift`, and related queue/chat-run coordination as the new path becomes verified. Do not delete native capability implementations merely because their callers change.

## Host-neutral agent package

`packages/agent` should be host-neutral, not Ox-neutral. It may own Ox's conversation/Profile mapping, document definitions, rich-message semantics, shared filesystem policy, and committed-state projection. Pi already supplies the generic harness; do not build another loop or parallel harness abstraction over it.

The bounded rollout now separates `core/session.ts` from `adapters/ios/`. The core has no native-global or compatibility-layer dependency, and its mutable state belongs to individual Sessions. The verified non-iOS host is an in-process test host with injected capabilities, not another finished product host.

### Core and adapter boundaries

The implemented entry points and layout are:

```text
packages/agent/src/
  index.ts         @openox/agent: native-free library entry
  core/            Shared Ox Session, Profile files/environment/tools, projections
  chat-bindings.ts Optional application UUID mapping over Pi conversation records
  adapters/ios/    @openox/agent/ios: bridge, model adaptation, JSC compatibility
  adapters/ios/storage-diagnostics.ts  Published Pi storage checks only
```

The shipped `harness.js` uses the iOS entry; `harness-storage.js` contains only upstream storage conformance/benchmarks and the native backend adapter. The dependency boundary must remain explicit. The shared core must not depend on iOS/native globals, Swift-specific wire messages, simulator cache paths, or iOS background-task APIs. Host adapters supply runtime setup, storage connections, models/networking, credential access, permission enforcement, and authorized capabilities. The adapter remains the security boundary even when the shared core requests approval.

Use Pi's existing `Storage`/`SqliteDatabase`, `Models`, tool registrations, and `ExecutionEnv` interfaces wherever they fit. Inject reporting and committed-state delivery instead of calling `native("report", ...)` or `native("agentEvents", ...)` from the core. Keep host-specific model-stream normalization and transport in the adapter. Inject Profile-scoped native artifact I/O behind Pi's filesystem interface instead of creating another harness abstraction. Native file ownership, durability, cancellation and permission checks remain the adapter's responsibility; dependency injection does not authorize a second database or file writer.

### Instance ownership and entry points

`openOxAgentSession(options)` now returns an instance owning the Harness, Profile files, registry, observers, projections and pending-run state. It injects Pi's SQLite facade and `Models`, registry/settings, blob-ID allocation, file authorization, reporting and committed-event delivery. Native request correlation stays in the runtime-bound iOS transport. Multiple core Sessions coexist in one JavaScript runtime without cross-talk; the host must still enforce one owner per database.

Use Pi's own conversation creation/configuration APIs through `session.harness`. Core `run`, `observe` and `abort` use Pi conversation IDs, including unbound conversations. The iOS adapter uses `ChatBindings` to resolve external chat UUIDs and route native models, tools and events. Persisted `ox.chat`/`chatID` and provider/extension names remain unchanged in this implemented extraction. Production adoption replaces the UUID bridge only through the identity/migration work below; no runtime legacy fallback is implied. Run completion is correlated with the terminal committed submission ID; completed request-ID deduplication does not wait for events that will not recur.

Importing the shared core must not install shims, access `__oxDurableRequest`, or initialize native resources. The iOS entry point explicitly loads the compatibility layer and creates its bridge. The reusable library, iOS adapter and upstream storage diagnostics remain separate. Continue auditing the shipped iOS bundle for forbidden Node dependencies, shell tools, and unsupported provider SDKs; host-neutrality does not relax Ox's no-shell policy.

### Refactor scope and verification

Make this a structural refactor before extending production integration. Preserve pinned upstream versions, document/storage formats, replay policy, permission behavior, temporary-chat restrictions, and activation gates. Do not migrate real Profiles or enable persisted-chat adoption as part of the extraction.

Native-free imports, injected in-process execution, isolated Sessions, unbound conversations, concurrent observation, deduplication, authorization, abort and cooperative close/reopen are covered by the portable suite. Earlier native mock/recovery and deterministic fixture results are historical; those custom campaigns have been removed. Retain upstream storage checks and verify application behavior through actual-chat E2E. Real-provider verification must be rerun with a working native login before claiming that gate. See the evidence below and the updated package README; additional production adapters remain planned.

## JavaScriptCore host

Bundle Pi Durable, its dependencies, the shared Ox core, and the iOS adapter into a single JavaScript bundle shipped with the app. Node.js/Bun and the bundler are development tools, not runtime dependencies on the phone.

Create a dedicated `JSVirtualMachine`/`JSContext` for the open harness's lifetime. Serialize JavaScript work on a chosen executor and return native asynchronous completions to that executor. Handle native/JavaScript ownership carefully, including managed references where needed, to avoid retaining a context through its bridge objects.

Provide production-quality implementations of the host APIs the selected bundle uses:

- `TextEncoder` and `TextDecoder`.
- Timers and `queueMicrotask`.
- `AbortController` and `AbortSignal`, including cancellation reasons, `throwIfAborted`, and `any`.
- URL support and the required cloning semantics.

Audit the final bundle for accidental Node dependencies. Do not assume browser compatibility means it runs in a bare `JSContext` without adapters.

`apps/ios/Ox/Host/VM/VirtualMachine.swift` currently creates a fresh context per snippet and binds bridge tasks to snippet lifetime. Reuse its asynchronous bridging pattern, not that lifecycle. The trusted harness context must remain separate from model-authored snippet execution. Snippets must not receive raw database access, credentials, or the privileged harness bridge.

## Native model and tool adapters

Expose existing Swift providers through Pi's model interface. Translate Pi transcript messages, positional system/tool changes, reasoning, tool calls/results, usage, and errors deliberately; the existing Swift provider contract is not a byte-for-byte match. Propagate cancellation to native streaming tasks. Support deferred generation only where the provider supports it.

Keep reusable credentials in Keychain and managed website sessions in WebKit. OAuth functionality must use apps registered as OpenOx. The integration must remain neutral to LLM provider.

Register Ox services and device capabilities as Pi tools. Enforce permissions in the native implementation even when an extension hook also requests approval. A selectable hook is not a security boundary. Persist approval decisions appropriately so interruption does not silently authorize a new effect or repeatedly ask an already answered question.

### No shell execution

Do not install the complete `CodingTools` extension, which includes `bash`. Register the supported tools individually.

- Do not register a shell tool.
- Do not bundle `NodeExecutionEnv`.
- Do not expose a process-launch/shell native bridge.
- If implementing Pi's `ExecutionEnv`, return `shell_unavailable` from `exec()`.
- Ensure tool diagnostics and instructions do not recommend unavailable shell operations.

The restricted JavaScript snippet tool may remain available. JavaScript execution is not shell execution, provided its bridge exposes only authorized capabilities.

## Profile folder and state database

Retain top-level `profile.json`, with the existing `id`, `createdAt` and `version` responsibilities, alongside one `state.sqlite` and `artifacts/`. SQLite is a component of the Profile, not its discovery manifest. Profile listing reads the manifest without initializing Pi or upgrading a database. Activation uses `StorageMigrator` to validate the manifest milestone, expected database format and artifact references before constructing consumers; a discoverable manifest does not prove that the remaining components are complete or compatible.

Do not maintain independently mutable identity/creation/migration fields in Pi documents. An immutable database-to-Profile binding may be checked to reject swapped databases, but it is an integrity check against the manifest, not a second manifest authority; define how duplication/import rebinds it. Pi's internal SQL/document/task versions remain its own compatibility information and are checked under the same activation gate.

Preserve the Profile folder as the lifecycle/export unit. Do not infer that copying an open folder creates a consistent backup, or that this enables iCloud/external live editing. Define native file protection and backup policy for all components before activation.

The portable backend needs an asynchronous `SqliteDatabase` facade with `exec`, `run`, `get`, `all`, `transaction`, and `close`.

Transactions must exclude unrelated operations across every awaited statement, resolve only after commit, roll back before rejecting, and expire their handles when the callback settles. Offload blocking disk work from the UI. Verify the backend's SQLite features, including STRICT tables and JSON functions, on supported iOS versions.

Bind operations to an immutable Profile scope and runtime generation. A Profile switch must not redirect an operation already in progress into another Profile. Reacquire harness handles after reopening. Do not concurrently open the same storage from another process or extension; keep Share Extension staging outside the database and import through the owning host.

### Pi-owned data

The SQLite backend stores conversations, immutable transcript entries, submissions, task checkpoints and terminal receipts, agent choices, committed live progress, and usage. Compaction changes model context without deleting original history.

### Profile-owned application data

Prefer Pi's typed documents for JSON/text state, avoiding a parallel persistence framework where its document semantics already fit:

- Profile-owned runtime settings, excluding identity/creation/format fields owned by `profile.json`.
- Memory and soul.
- Artifact metadata, saved state, size/integrity information and relative file references (not duplicated artifact contents).
- Profile-owned skill packages and selections.
- Other structured application state explicitly assigned to the Profile.

Profile-wide content uses Session-scoped documents. Conversation presentation uses conversation-scoped documents for title, favorite, read/unread state and application-only settings. Model/thinking/tool choices stay in `pi.agent`; do not duplicate them in a separate chat record. Derive sidebar previews from committed entries where possible. Leave Pi's `ConversationRecord` and SQL tables unchanged; Ox-specific state belongs in documents/entry payloads, not ad hoc upstream columns. A document may keep an existing Ox kind when its semantics remain compatible; removing the identity binding or changing kinds requires explicit conversion, not a source-only rename.

Long-lived artifact metadata must not be task-scoped: task documents retire on terminal settlement. Decide history/fork policies explicitly and keep payloads separately addressable rather than loading every artifact into one document. Define checkpoint policies for long-lived documents. Pi does not automatically bound delta tails; the current Ox file/presentation documents now checkpoint every 32 ordinary changes after the source-review smoke below reproduced accumulation.

Pi documents contain strict JSON, not raw bytes. Production artifact contents, including Markdown/text artifacts, live as files under `artifacts/`; metadata stores references such as `artifacts/report.pdf`. Do not persist absolute container URLs or reference unmanaged external files as Profile-owned content. Import external/Share Extension bytes through the owning host. No production `ox_blobs`/`ox_blob_chunks`, parallel chat table, or mock receipt table is required by this design.

### Artifact publication and lifetime

- Normalize references as Profile-relative paths with flat artifact basenames. Reject traversal, absolute paths, symlinks escaping the managed root, hidden staging/private database paths, and stale Profile/runtime scopes at native access. Enforce containment at the actual native open, not only with an earlier canonical-path check; a rename/symlink race must not reach private or external files.
- Stage incomplete writes privately, complete the file and establish native file/directory durability, then commit metadata/reference changes through Pi. Serialize native/agent read-modify-write operations through one owner. Replace the current SQLite-backed `flushFile` no-op with real file durability semantics.
- There is no atomic SQLite-plus-filesystem transaction. A failure before the reference commit may leave an orphan; an acknowledged reference must not point to an unpublished file. Specify recovery at each boundary. A tool's reference commit may also precede its tool-result commit; replay safety still requires stable intent/idempotency or interruption handling.
- Choose overwrite/rename semantics before implementation. Do not silently repoint historical attachments by reusing a filename. Prefer distinct readable filenames for referenced versions; allow a deliberate latest-file reference only when that is the product contract. Decide how Pi write/edit returns or exposes a replacement filename without silently changing its tool semantics.
- Reclamation must account for current artifacts, saved items, transcript/rewindable references, pending work, active readers and exports. Logical deletion cannot remove a file still needed by another root. Missing/corrupt referenced files are explicit errors, not empty content.
- SQLite metadata controls references and saved state. Directory enumeration may diagnose/reclaim unreferenced files; it must not silently import external edits as a second authority.

## Virtual filesystem and agent interface

The filesystem is a capability API over mixed backing: Pi documents for suitable structured/text state and native files for artifact contents.

```text
MEMORY.md                 -> Profile document
SOUL.md                   -> Profile document
artifacts/report.md       -> physical artifacts/report.md + Pi metadata
artifacts/chart.png       -> physical artifacts/chart.png + Pi metadata
skills/example/SKILL.md   -> Profile skill document
chats/<conversation-id>/... -> read-only Pi transcript/metadata projection
```

The `chats/` namespace is virtual and scoped to this Profile; it is not a physical chat directory or another identity registry. Reuse Pi's binary/directory reader contracts when the adopted release includes them, including opened-file lifetime and bounded reads. They require an Ox native implementation; Pi's Node filesystem is not an iOS backend. Keep only the capability subset permitted by Ox and exercise upstream filesystem cases without enabling shell execution.

Other mounts may resolve to bundled resources, native Git working trees, or user-granted external folders. Database-private state and physical host paths remain inaccessible.

A prompt section describes the namespace and available tools. The model discovers content through listing/search tools and reads it through tool calls; it does not receive every file automatically.

Supply a Profile-bound execution environment that resolves canonical virtual paths and implements file reads/writes and metadata operations. Its filesystem identity must distinguish Profiles, while all environments accessing the same Profile namespace share that identity. Path normalization must enforce containment rather than expose actual app-container paths.

### Remove duplicate public read/write/edit APIs

Use Pi's `read`, `write`, and `edit` as the agent-facing tools. Remove:

```text
ox.fs.read
ox.fs.write
ox.fs.edit
```

Retain one private backend for storage, mount resolution, permissions, validation, and artifact presentation. Use thin tool wrappers where Pi's generic behavior does not match Ox's requirements. Retain custom tools for directory listing, glob/grep, deletion, and richer document/image operations; Pi's bundled text reader does not replace those capabilities.

Pi tools are model-callable tools, not automatically JavaScript functions. After removing the methods above, snippets cannot call them. A snippet can return bounded content for a subsequent Pi write, or use an appropriate dedicated artifact operation for larger output. Update prompts, skill scripts, and other callers; handle affected older persisted content through the compatibility gate.

Pi serializes its own edit/write calls by filesystem identity and canonical path, but that queue does not serialize native UI writers. Coordinate all mutations, including the read-modify-write interval of edits, so native edits cannot be lost. Retain a custom atomic edit path if the generic tool cannot meet this requirement.

## Projections and presentation

Render chats from Pi's committed conversation snapshots and updates. Do not publish raw provider output through a separate volatile UI path. Observe application documents separately where needed; third-party documents are not automatically included in Pi's built-in conversation view.

Expose chat-history paths as read-only projections from Pi entries. Do not maintain a second authoritative `turns.jsonl` beside the database.

Use managed artifact files directly for native previews/file-URL APIs where safe. Materialize disposable copies for document-backed content, transformations or sharing when needed; those copies are not authoritative. Artifact contents are authoritative files, while Pi owns their metadata/references and conversation state. Opening a native preview must pin its file against reclamation.

The following remain outside the Profile database:

- Keychain secrets and native credential state.
- WebKit website data.
- User-owned external files and device folder grants.
- Git service repositories and working trees.
- Device-owned diagnostics, app preferences/schedules unless explicitly redesigned, and temporary resources.

Keep structured diagnostics on-device and user-owned. Never log credentials or reusable secrets.

## Export/import, not sync

No live Profile synchronization, raw SQLite-file syncing, external in-place Profile editing, or bidirectional projection reconciliation is part of this plan.

Export a consistent, versioned Profile package containing `profile.json`, a database snapshot and the artifact files referenced by that snapshot, with package integrity information. Its archive encoding remains to be chosen. Capture the manifest/database/reference set under the Profile owner's lifecycle coordination and pin files against overwrite/deletion/reclamation until export finishes. Any export-package manifest is derived packaging metadata, not another live Profile authority. Never copy an active database file without accounting for outstanding WAL content. Credentials, grants, website sessions, device state, staging and unreferenced cache files are not implicitly included.

Import validates the Profile manifest and its agreement with database binding, supported versions, package paths/symlinks, database integrity, content limits, file digests and reference completeness; stages the entire Profile; then installs it. Define duplicate Profile identity and reference-remapping behavior explicitly. If Pi IDs are preserved, their namespace changes with Profile identity; record-based import that reallocates IDs must remap every affected reference. Do not interpret numeric-ID collisions across databases as global identity.

Imported pending work must not silently execute. Establish the import execution policy before any `resume`, submission, or wait call can enable scheduling. Preserving task records for inspection is not permission to run their effects.

## Recovery and iOS lifecycle

Pi resumes durable task checkpoints, not JavaScript instruction pointers. Reopening an interrupted generation may resend the model request and incur additional spend. A request ID deduplicates submission admission, not arbitrary external effects.

Only declare a tool replay-safe when it is genuinely safe to rerun or uses stable, correctly scoped idempotency keys. Arbitrary JavaScript snippets can perform several external effects and must default to unsafe replay. Interrupted unsafe actions may need reconciliation or user attention; do not blindly retry them.

Distinguish execution interruption from user cancellation:

- `Harness.close()` stops admission, signals/joins work, and preserves checkpoints without writing cancellation outcomes.
- Conversation/task abort commits cancellation intent and runs abort behavior.

Close is cooperative and can wait for non-cooperative code. iOS may terminate the app without allowing it to close. Persist progress as work happens, not only in an expiration handler.

`BGContinuedProcessingTask` can extend user-started foreground work; scheduled background execution is opportunistic. Neither guarantees execution after termination. Pi's task-level `background` flag describes ownership/abort/idle behavior, not an iOS background entitlement.

After an ordinary restart, recreate the runtime, reinstall extensions, reopen storage, reacquire handles, and resume locally authorized work. Do not confuse this recovery path with importing another Profile's pending tasks.

## Migration and rollout

Keep all application persisted-format compatibility behind `StorageMigrator` in `apps/ios/Ox/Host/Profile/StorageMigration.swift`. Do not add another application migrator or migration file. Establish how upstream SQLite/document/task version handling fits that gate before adoption. Reject unsupported future representations without overwriting them.

Preserve a recoverable original during conversion from the current Profile directory layout to `profile.json` plus `state.sqlite` and `artifacts/`. Retain the manifest's stable identity and creation date. Stage and validate the complete destination before activation; atomically publish the manifest's appended immutable milestone only after the database/files are ready. Interrupted conversion must not advertise a completed Profile through a prematurely updated manifest. Keep restart-safe old-UUID-to-Pi-ID conversion bookkeeping within `StorageMigrator`, not a normal runtime chat registry. Translate native/RPC/UI references, deep links, scheduled-run associations and imported packages deliberately; decide whether legacy external references require a limited compatibility mapping. Do not rewrite durable external-effect keys simply because application IDs change.

Verify rich transcript/context continuation, provider signatures/IDs, artifact references and saved state, skill ownership, interrupted conversion and no-op second activation before removing the source. Resolve compacted legacy context as well as full scrollback; do not seed only the active messages and lose history. Discovery/bootstrap/version probes must pass through the compatibility gate before any Pi initialization or storage consumer. Existing iCloud/external Profiles need an explicit transition/import path, including hydration/unavailability/collision handling; do not open a new live database in those locations implicitly.

The host-neutral extraction is complete within the bounded rollout. Preserve its unchanged persisted formats and activation boundaries. Before extending adoption, complete the outstanding real-provider rerun and production gates; structural isolation alone does not authorize persisted-chat attachment or Profile conversion.

### Remaining implementation sequence

The Session extraction and upstream storage diagnostics are implemented.
Phase 2 has immutable native physical artifacts; phase 3 has qualified presentation
and full-history routing while native UUID compatibility remains. These are bounded
rollout primitives, not completed production adoption. The custom phase 4/5 package
and conversion experiments, normalized installer and fault-injection campaigns
have been removed. Production export/import and conversion must still be implemented
and verified through the actual application path.

The following phases still need their production exit gates. Each must leave a
bounded integration path testable before proceeding.

1. **Finalize the Profile contract and identity transition.** Retain `profile.json` for Profile identity/creation/migration version; define manifest validation, database binding and native discovery/activation without duplicate manifest fields in Pi documents. Define conversation presentation documents, rich entry/attachment references and document checkpoint/history/fork policies. Choose artifact overwrite/rename/retention, filename collision and import identity policies. Inventory UUID-typed routes in `ChatModel`, Host protocol/CLI, providers/tools, notifications, schedules and package formats. Specify Profile-qualified Pi IDs without changing provider/extension names or reusing provider cache UUIDs as application IDs. Exit: reviewed formats and reference-conversion map, with no new parallel execution/chat authority.
2. **Replace fixture binary storage with injected native artifact files.** Adapt `core/profile-files.ts`, `core/profile-env.ts`, `core/session.ts` and iOS bridge ownership to physical artifact I/O while memory/soul/skills remain document-backed. Replace blob-ID allocation/SQL chunk operations with scoped relative-path I/O; bound reads/writes and define file publication/recovery/reader lifetime. Remove binary SQL tables only after all callers and integration fixtures use the new backend. Use fresh debug fixtures; reject stale formats or route any required conversion through `StorageMigrator`, never a runtime legacy reader. Audit/pin a published Pi release before using the currently unreleased reader contracts. Exit: native file/metadata round trips, interruption, containment and Profile-switch isolation pass without production activation.
3. **Move application routing/presentation onto Pi conversations.** Update the iOS adapter, native chat models and Host/RPC/CLI boundaries to Profile-qualified Pi IDs. Render full fork-aware scrollback and built-in/Ox documents, preserving rich blocks, provider continuation, model choices, timestamps, outcomes and attachments. Keep UI models as projections, not writable transcripts. Introduce this routing behind the bounded rollout first; keep current UUID adapter compatibility until migration and every affected caller are ready, then retire `ChatBindings`/identity-only `ox.chat` use in phase 7. Exit: multiple visible/internal conversations, colliding IDs in independent Profiles, committed hydration/reopen/overflow and native capability routing pass.
4. **Implement consistent Profile export/import and lifecycle.** Snapshot database state and referenced files under one owner; pin files, validate a versioned manifest, stage imports and decide duplicate identity/reference remapping. Enforce dormant imported work before any progress-enabling Pi API. Integrate create/rename/duplicate/delete, preview/share and Share Extension staging without opening SQLite from another process. Exit: exports during writes/cleanup, complete round trips, malformed packages and interrupted import preserve source/destination integrity.
5. **Implement real-Profile conversion in StorageMigrator.** Append the version milestone and predecessor-produced before/after fixtures. Retain `profile.json` identity/creation fields, convert `chat.json`, `turns.jsonl`, compacted context, `.saved.json`, memory/soul/skills and their references into the reviewed target, then publish the new manifest milestone only after validation; preserve artifact basenames/content where valid. Hydrate iCloud sources or defer, stage destination, resume safely after interruption and fail closed on collisions/future versions. Exit: startup/activation gate runs before readers, second activation is a no-op and recoverable originals remain available.
6. **Complete native capability, UI, provider and lifecycle parity.** Verify permissions/approval persistence, steering/follow-ups, subagents, compaction, retries/deferred/media, recovery and foreground/background leases. Restore provider login only with authorization; the current ChatGPT HTTP 401 remains an outstanding gate. Measure actual document/file workloads, long delta tails, large files and native memory on supported simulator/device targets; published Pi storage timings do not cover the new artifact backend. Exit: retained integration/native E2E campaigns and human UI review pass with documented device/OS coverage.
7. **Activate and remove superseded paths.** Enable converted Profiles only after the previous gates; remove legacy Swift loop/compactor, per-chat transcript persistence and duplicate public file tools when all replacement consumers are verified. Preserve native credentials, permissions, Git, WebKit, diagnostics and device-owned state. Update canonical storage/API documentation in the same implementation changes. Exit: one Pi execution/transcript authority, one Profile folder store, no implicit persisted-chat adoption or silent legacy fallback.

Use `sim` and `ox` for app testing, obey simulator ownership rules, keep diagnostics outside the repository, and provide screenshots for UI review.

### Verification gates

- Core import without native globals/shim side effects, in-process host execution through injected capabilities, and multiple Session instances without shared mutable state.
- Existing iOS JSC/native campaigns pass after adapter extraction; no persisted-format or production-activation changes are hidden in the refactor.
- SQLite adapter conformance, transaction exclusion, rollback and failed-rollback behavior.
- Supported-iOS SQLite feature availability.
- Model message/stream translation, usage, compaction, and cancellation fidelity.
- Safe/unsafe tool interruption after an effect but before its result commit.
- Permission pause/relaunch and deliberate cancellation versus OS expiration.
- Concurrent conversations, equal numeric IDs in separate Profiles, and native/agent edits without cross-Profile access.
- UI hydration/full scrollback from committed snapshots without a second transcript authority; UUID reference conversion and hidden/internal conversation handling.
- Document checkpoint/reopen behavior with bounded delta replay; rich message and attachment fidelity.
- Physical artifact path containment, bounded readers/writers, overwrite/rename policy, missing/corrupt content, reader pins and reference-aware reclamation.
- Interruption before/after file publication, reference commit and tool-result commit, plus permission/lifecycle gates.
- Predecessor-produced migration fixtures, interrupted conversion recovery, fail-closed future versions, source preservation and no-op second activation.
- Export consistency during file writes/reclamation, import validation, duplicate identities/reference remapping, interruption and dormant imported work.
- Memory, bridge overhead, and large-artifact behavior on supported devices.

## Evidence and remaining decisions

The results below describe earlier builds. Removed proof/fixture campaigns are
historical evidence, not runnable acceptance checks or verification of this cleanup.
Current commands are maintained in the package README.

### Historical isolated iOS proof (removed)

The former implementation bundled pinned Pi Durable, pi-ai, and Chord 1.0.0
into a dedicated JavaScriptCore context with asynchronous native SQLite and a
Swift-selected mock model/native tool. Its custom harness and replay campaign have
been removed; only the upstream storage checks remain. Results below describe the
previous implementation and do not substitute for current actual-chat E2E.

On `ox-3` running iOS 26.0, all 23 upstream storage conformance cases passed through
the native adapter. The E2E campaign also passed host API checks, transaction
exclusion/rollback/handle expiry, STRICT/JSON availability, lossless SQLite bindings,
committed streaming/usage, request-ID deduplication, native permission denial,
model cancellation, cooperative close/reopen, concurrent isolated scopes, and app
termination/relaunch after a mock effect but before its result commit. Safe recovery
reused the native receipt; unsafe recovery did not repeat the effect. SQLite
integrity checks passed. At that stage the portable suite had 43 passing tests;
repository typecheck and 14 live Host RPC tests also passed.

This is not production model-stream translation, persisted approval recovery,
compaction verification, Profile storage/migration, UI replacement, export/import,
a device/power-loss test, or a full performance/memory campaign. iOS 27 verification
remains blocked by absent `ox-4`/`ox-5` devices and runtime. Upstream schema,
document, and task compatibility must still be integrated through `StorageMigrator`
before any real Profile uses this backend.

### Native temporary-chat rollout

`debug.durable.chat` attaches only idle temporary chats to a shared, UUID-bound
cache Session under `PiDurableProof/Native/`; persisted chats remain refused. The
runtime now adapts real Swift provider streams and native tools, with Swift-owned
credentials/permissions and committed partial reconciliation in normal chat
presentation. The legacy runner, compactor and run configuration are grouped under `Host/Agent/Legacy/`
and retained for every nonattached chat behind `Agent.runLegacy()`; their
snapshot/queue/compaction setup is no longer constructed on the Pi path. It can
be deleted only after saved-chat conversion supplies the replacement path.

The integration lives in `packages/agent` (`@openox/agent`); its host-neutral
Session core is now separate from the iOS adapter. Pi's conversation records
are authoritative; the redundant `ox.chats` registry is no
longer created or consulted. Per-conversation `ox.chat` stores only Ox's external
UUID because Pi 1.0 uses numeric IDs. A disposable lookup is reconstructed from
Pi records at open, and identity collisions fail closed.

A fresh `ox-3` build passed the reproducible ChatGPT `gpt-6-sol` campaign: an exact
text response; dedicated read/write/edit and native execute; actual edited content
and committed tool results; absent trusted globals in the snippet realm; reopened
runtime file/transcript hydration; and two conversations in one Session. Codec
fixtures passed opaque signature/ID, usage (disjoint Pi cache counters), unknown
cache-write, attachment-reference and diagnostic/activated-skill round trips.

Synthetic `ox.profile`/`ox.file` documents and a restricted VFS now serialize all
native/agent file edits. Native conformance passed Unicode, atomic edits, failed
write preservation, 200 KiB text/32 MiB binary limits, a 524,291-byte round trip in
128 KiB chunks, replacement/reclamation and integrity. Blob commits precede Pi
reference commits; failed reference writes can leave reclaimable orphans. This
ordering is explicit, not a claim of one combined binary/document transaction.
The tool namespace is deliberately distinguished from real `ox.fs`; temporary-chat
restrictions on real Profile writes remain unchanged.

Testing reproduced two rollout issues before fixing them: positional system
records incorrectly reached the native presentation decoder and closed its watch,
leaving a completed model turn waiting; and legacy temporary-chat instructions
made the model confuse synthetic file tools with prohibited real Profile writes.
Projection closures now reject waiters and stop further execution instead of
silently hanging; immutable replacement frames are detached before later deltas.

This remains a **bounded rollout, not architecture completion**. Full committed
snapshot UI restoration (overflow currently fails closed), durable approvals,
Session execution leases, steering/follow-up/hook/compaction/deferred/media parity,
real services/subagents, production artifact/skill semantics, Profile compatibility
conversion and export/import remain gates. Cache conversations may contain user
context/replies/native diagnostics and must be treated as private on-device test
state. iOS 27/device, large-artifact and memory/OS-expiration campaigns remain
unverified. No real Profile format or storage consumer has switched.

### Host-neutral extraction verification

On `ox-1`, iOS 26.0, after extraction:

- 51 portable integration/conformance tests remain after removing nine isolated
  unit-style cases; the retained suite and repository typecheck/boundaries passed.
  The earlier 14 Host RPC tests passed, including the live Host case.
- Audited native and proof bundles passed bare-realm loading with explicit iOS
  compatibility setup, without Node/browser globals or external runtime imports.
- The complete native mock/storage/recovery campaign passed.
- The existing deterministic native-provider fixture passed text, paced streams,
  tool rounds, seeded history, binary I/O and Session reopening. One retained
  iteration is functional regression evidence, not a performance conclusion.
- Native Mock temporary chats passed committed reasoning/text presentation, runtime
  reopen without duplicate transcript seeding, and two conversations in one Session.
  Screenshot and diagnostics remain outside the repository.
- The real ChatGPT rerun passed codec/file/storage checks but its first user turn
  failed on token-refresh HTTP 401. The failure settled with no pending work; no
  credentials were reset and the send was not retried. Earlier real-provider
  evidence does not establish successful real-provider parity for this refactor.

Tests reproduced and fixed concurrent observer attachment opening duplicate watches,
and Swift's Session-level `chatID: null` being mistaken for a conversation lookup.
No real Profile migration, persisted-chat adoption or storage-format change was made.
The remaining production gates above still apply.

### Upstream storage benchmarks

The former standalone benchmark runner used the published Pi Durable 1.0.0 storage workloads
through the actual JSC/native SQLite facade. It has been removed with the replay runners;
the native diagnostics retain upstream workloads. The runner imported upstream seeds,
12 read/three write workloads, expected results, scales and record-count helper;
it does not fork the benchmark definitions. It opens fresh synthetic fixtures
without a Harness, scheduler, model requests, mock receipts or Ox binary store.
Read sweeps share one seeded dataset; each write warmup/sample has its own fresh
runtime/database and upstream baseline. Native monotonic clocks measure operation
wall time including bridge/backend work; setup/close and integrity checks are separate.
Current fixtures close/remove on success/error, reject stale reuse and concurrent
storage diagnostics, and never enter real Profile activation or export. They use
`debug.durable.storage` and `PiDurableDiagnostics/<action>/<uuid>/`; the former proof
endpoint, receipt table and custom recovery campaign are no longer present.

On `ox-1`, iOS 26.0, SQLite 3.51.0, all workloads passed at the published timing,
1k and 10k read scales with three retained samples each. Native invalid-request,
proof/concurrent-owner exclusion and stale-fixture checks passed; the namespace
was empty afterward. The new native clock and trusted bridge globals were undefined
in snippet execution. The existing complete native storage/recovery campaign
passed after wiring. No isolated unit tests were added.

See the [native diagnostics methodology](../packages/agent/README.md#upstream-storage-benchmarks).
Raw measurements remain outside the repository. WAL/FULL differs from upstream
Node's NORMAL default; whole-app process gauges are not isolated backend memory
measurements. These are small DEBUG Simulator diagnostics, not device/production
performance claims or completion of the remaining adoption gates.

### Synced upstream storage review

The local `../pi` checkout was fast-forwarded to `1b094148b91d737fb398bf1591604de58ec169e1`. Document definitions, storage implementations and Chord JSON/delta code are unchanged from v1.0.0. Documents remain strict JSON; the SQLite facade accepts `Uint8Array` but Pi supplies no blob-record store or custom-file transaction integration. Synced main adds `openBinaryReader`, `openDirReader` and environment conformance cases, listed as Unreleased; Ox remains pinned to 1.0.0 and must audit a release before adopting them.

Ad hoc local checks passed strict-JSON rejection of raw typed arrays, upstream Node filesystem positional/EOF/opened-file identity, and one-BLOB range reads through Ox's portable facade. They confirmed that chunk tables are not required by Pi, but are not native iOS or performance evidence. A real Pi/Ox file integration check left one base and 40 deltas after 41 writes because `ox.file` has no checkpoint predicate. Define bounded checkpoint policies before production adoption. No runtime, dependency or Profile format changed during this review; the folder/artifact-file plan supersedes the binary-database proposal rather than describing a completed conversion.

### Earlier macOS investigation

A standalone macOS JavaScriptCore probe using the published Pi Durable, pi-ai, and Chord 1.0.0 packages passed native Swift tool execution, portable SQLite persistence, request-ID deduplication, and abrupt process termination/recovery. Replay-safe recovery reused a native receipt; replay-unsafe recovery did not repeat the effect and produced an interrupted result. SQLite integrity checks passed.

That probe used a deterministic faux model and investigation-only compatibility shims. It was not an iOS simulator/device test, a production native-model integration, a complete SQLite conformance run, or a binary-artifact implementation. Temporary probe artifacts are intentionally outside the repository.

Remaining decisions include artifact overwrite/rename and historical-reference policy, native file publication/reclamation, document definitions/checkpoints/indexing, Profile discovery/bootstrap/backup policy, scoped application identity and legacy-link compatibility, rich-message/admission correlation, export manifest/imported-work policy, existing Profile transition behavior, and the precise wrappers needed around Pi file tools. The Profile-folder layout and removal of a separate production chat identity store are agreed targets; their implementations and activation gates remain outstanding.

## References

- [Pi Durable announcement](https://earendil.com/posts/pi-durable/).
- [Pi Durable README](https://github.com/earendil-works/pi/blob/main/packages/durable/README.md).
- [Pi Durable specification](https://github.com/earendil-works/pi/blob/main/packages/durable/docs/spec.md).
- [Durable coding-agent example](https://github.com/earendil-works/pi/tree/main/packages/coding-agent/src/experimental/durable).
- [Vacation-agent example](https://github.com/earendil-works/pi/tree/main/packages/coding-agent/src/experimental/vacation).
- [Portable execution environment](https://github.com/earendil-works/pi/blob/main/packages/durable/src/env/index.ts).
- [Current Ox storage map](../.agents/skills/migrate/references/storage.md) — remains the description of implemented storage until migration lands.
- Apple: [JSContext](https://developer.apple.com/documentation/javascriptcore/jscontext), [JSVirtualMachine](https://developer.apple.com/documentation/javascriptcore/jsvirtualmachine), and [long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados).

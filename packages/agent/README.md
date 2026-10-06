# Ox Agent

Host-neutral Ox Sessions backed by pinned `@earendil-works/pi-durable` 1.0.0. Production iOS Profiles and temporary chats now use this execution path; the Swift legacy loop has been removed. Full rollout acceptance is still in progress: a passing package/native smoke is not a released-predecessor, lifecycle, media, or physical-power-loss guarantee.

## Authority and hosts

`openOxAgentSession(options)` owns an instance-local Harness, model registry, Profile files, and committed projections. Hosts inject storage, models, tools, authorization, artifact files, reporting, and committed events. The public entry point is native-free; `src/adapters/ios` supplies the trusted JavaScriptCore bridge. Swift owns credentials, platform capabilities, approvals, file/database I/O, and committed UI presentation, not execution or a mutable competing transcript.

Production identity is `{profileID, conversationID}`. Conversation IDs are database-local; references and history cursors are Profile-qualified. Production attachment configures an existing conversation's ephemeral native route without creating `ox.chat` UUID documents. `src/chat-bindings.ts` retains explicit temporary/debug UUID compatibility only. There is no `ox.chats` registry.

Full fork-aware history and active model context are distinct. Native rich turns are immutable presentation decorations; canonical Pi models own text, calls, and results. Runtime code never decodes migration `sourceJSON` archives. Model/provider credential metadata lives separately from Pi transport aliases. Forks retain Pi history/compaction semantics and receive independent current native transport/extension routes.

## Profile storage

```text
<Profile>/
├── profile.json
├── state.sqlite
└── artifacts/<filename>
```

The manifest owns identity, creation date, and migration milestone. Pi owns execution, history, and application documents; database identity/backend documents are integrity bindings. Flat artifacts, including text, are immutable ordinary files, not SQL blobs. Native descriptor-relative publications flush verified bytes before committing metadata/references; failures can leave harmless unreferenced bytes. Logical removal retains historical files. Different bytes require a new filename, and physical orphan collection is unsupported.

`installOxProfile` installs host-normalized drafts into an unopened fresh dormant database, validates ledger/context/documents/physical artifacts, then closes before the host stamps a manifest. It has no legacy decoder or model/tool execution. All iOS compatibility transforms, journals, source mappings, milestone gates, and publication recovery belong to `Host/Profile/StorageMigration.swift`. Local activation opens/validates the new owner before publishing the scope. Live SQLite/cloud synchronization, external in-place changes, and copying an active database are unsupported. See [the canonical storage map](../../.agents/skills/migrate/references/storage.md).

Whole skill-package changes use one document/index transaction. Artifact metadata is `{path,size,sha256}`; provider media receives verified request-owned bytes, while previews/shares use verified bytes or lifetime-owned snapshots. Metadata URLs are routes, not byte-snapshot proof.

## Recovery

Opening a Harness is dormant; asking for progress can schedule every surviving task in the Session. The iOS adapter inspects and admits all surviving native configurations before submit/wait/resume/abort, including observer-error abort paths. Missing historical models, mismatched transport routes, or unavailable native configurations fail closed without rewriting checkpoints or admitting new input.

`resumeExisting` waits for the existing submission receipt and final committed native-event delivery. It does not resubmit user input. Cold native tools restore missing context from actual Pi task/calling-assistant proof, preserve cached normal generation context, and never rerun native transform/before-request hooks. Parallel tools share hydration and await native UI presentation readiness. Unsafe interrupted intents remain interrupted, not replayed.

Close cooperatively preserves durable recovery; Stop durably aborts. Request IDs are not an exactly-once guarantee for external effects. A failed storage admission can poison a Session even after SQLite rollback: explicitly close/reacquire and diagnose; never blindly retry inputs or effects through the failed Session. Native post-turn `shouldStopAfterTurn` eval limits are unsupported; `agents.evaluate` fails explicitly before invoking providers/tools.

## Verification

```sh
bun run build:agent
bun run test:agent
bun run typecheck
bun run test:e2e
bun run test:agent-ui-ios --device ox-1 --app /absolute/Ox.app --evidence /tmp/evidence
```

Bundles `harness.js` and `harness-storage.js` are audited for bare JavaScriptCore: no Node runtime, shell, or module imports. Model-authored snippet VMs are separate. Retained integration/disk checks and published upstream storage conformance/benchmarks verify the shared boundary; retired custom mock/effect/fault/package/conversion controllers remain removed.

The native UI runner uses Mock, temporary chats, reasoning/Markdown, real native snippet tools, Stop, scoped identities, SQLite inspection, and process reopen. `OX_DURABLE_TEMPORARY_SESSION=<UUID>` selects a QA cache identity; ordinary temporary chats also attach automatically. The runner does not change Host access or credentials. Diagnostic RPCs remain Debug Simulator-only. Private stopped-process SQLite copies, screenshots, logs, and predecessor backups belong outside the repository and are not Profile exports.

Current production simulator evidence includes successful local migration/activation, persisted normal/native-tool chats, canonical rehydration, interrupted-model recovery, and qualified regeneration. Remaining acceptance includes native cold-tool interruption, complete Profile lifecycle/closed snapshots, predecessor publication failures, and media/share UI parity. Physical phones are not implied by simulator evidence.

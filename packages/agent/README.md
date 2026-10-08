# Ox Agent

Host-neutral Profile runtimes backed by pinned `@earendil-works/pi-durable` 1.0.0. Production iOS Profiles and temporary chats now use this execution path; the Swift legacy loop has been removed. Full rollout acceptance is still in progress: a passing package/native smoke is not a released-predecessor, lifecycle, media, or physical-power-loss guarantee.

## Authority and hosts

`openProfileRuntime(options)` opens one Profile's execution resources through `ProfileRuntime` in `src/profile/runtime.ts`. It owns an instance-local Harness, model registry, Profile files, and committed projections; closing it does not delete the Profile. Files, filesystem views, conversations, presentation, and installation live alongside it in `src/profile/`; shared prompts and capability guidance remain in `src/core/`. Hosts inject storage, models, tools, authorization, artifact files, reporting, and committed events. The public entry point is native-free; `src/adapters/ios` supplies the trusted JavaScriptCore bridge. Swift owns credentials, platform capabilities, approvals, file/database I/O, and committed UI presentation, not execution or a mutable competing transcript. Its `Conversation` submits directly through `DurableRuntime` and receives committed events directly; there is no Swift `Agent` facade or execution driver. RPC model messages are read from Pi's active context.

`composeOxPrompt` in `src/core/ox-prompts.ts` defaults to a static portable scaffold. The iOS adapter explicitly selects the full `oxScaffold`; other adapters may supply their own complete scaffold. Execution guidance likewise has explicit `portable`, `ox`, and `website` variants. Keep some wording duplication rather than infer instruction inclusion from prose or patch rendered sentences. Hosts supply persona, frozen memory, host/Profile scopes, supported functions, presentation, and per-turn facts. Service mounts are explicit facts, not iOS domain assumptions. Host context is prompt provenance, not authorization or a multi-host execution dispatcher. Native permissions remain authoritative; scoped turns must match their attached host/Profile.

Templates and capability help live in `src/core/{prompts,tool-prompts,runtime-prompts,provider-prompts,guidance-texts}.ts`. `build:agent` emits the host-neutral `prompts.js`, default SOUL resource, and `ModelGuidance.generated.swift` snapshot for non-throwing native metadata getters. Edit the TS source, never the generated Swift. The untagged `ox` section, `oxTransientContext` blocks, and persisted formats are unchanged.

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

Opening a Harness is dormant; asking for progress can schedule every surviving task in the Profile's Pi Session. The iOS adapter inspects and admits all surviving native configurations before submit/wait/resume/abort, including observer-error abort paths. Missing historical models, mismatched transport routes, or unavailable native configurations fail closed without rewriting checkpoints or admitting new input.

`resumeExisting` waits for the existing submission receipt and final committed native-event delivery. It does not resubmit user input. Cold native tools restore missing context from actual Pi task/calling-assistant proof, preserve cached normal generation context, and never rerun native transform/before-request hooks. Parallel tools share hydration and await native UI presentation readiness. Unsafe interrupted intents remain interrupted, not replayed.

Close cooperatively preserves durable recovery; Stop durably aborts. Request IDs are not an exactly-once guarantee for external effects. A failed storage admission can poison a Profile runtime even after SQLite rollback: explicitly close/reacquire and diagnose; never blindly retry inputs or effects through the failed runtime. Behavioral evals drive ordinary chats through the Ox CLI, independently observe state through existing APIs, and probe results in fresh chats; no eval-only runtime hooks are installed.

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

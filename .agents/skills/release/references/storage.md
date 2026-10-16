# On-Device Storage

This is the canonical map of state Ox persists. Update it whenever a storage
location, retention rule, backup policy, or owning component changes. Encoded
types remain authoritative in their `Codable` implementations.

## Storage map

```text
<app container>/
├── Library/
│   ├── Preferences/                         UserDefaults
│   │   ├── app.hasCompletedOnboarding       onboarding completion
│   │   ├── savedServices                    attached service domains
│   │   ├── actionApprovalPolicies           versioned Automatic, Ask, Allow, or Block policies for Actions
│   │   ├── api.url                          Ox service API override
│   │   ├── llm.defaultModel                 new-conversation provider/model/thinking selection
│   │   ├── llm.providerCatalog              added provider definitions and bundled overrides
│   │   ├── app.region                       last detected network region
│   │   ├── app.language                     UI and agent language override
│   │   ├── host.allowConnections             app-wide Host access toggle; absent means off
│   │   ├── conversation.importMemoryIntentDisplays   app-wide count of starter intent displays, capped at three
│   │   ├── speech.voice.identifier          legacy read-aloud voice preference, ignored and retained
│   │   ├── storage.activeProfile            active profile UUID
│   │   └── chatgpt.installationId           per-install Codex client ID
│   ├── Application Support/
│   │   ├── service-repositories.json        built-in, Local, Development, and installed repository enablement; conflict resolutions
│   │   ├── mounted-repositories.json       version 1 repository bindings to Files grant IDs and relative folders
│   │   ├── service-repositories/development/ simulator development HEAD snapshot
│   │   ├── RepositoryStaging/              private repository downloads, recoverable snapshot backups, and mutation staging
│   │   ├── RepositoryMigrationBackups/     retained predecessor repository-skill migration sources
│   │   ├── external-profiles.json           selected Profile folder bookmarks and optional display names
│   │   ├── device-folder-grants.json         Profile-bound native folder bookmarks; nullable profileId means unassigned
│   │   ├── scheduled-skills.json             device-owned scheduled skill snapshots
│   │   ├── Profiles/<uuid>/profile.json    predecessor registration and downgrade guard
│   │   ├── Profiles/<uuid>/state.sqlite    retained predecessor database; inactive after portable migration
│   │   ├── Profiles/<uuid>/staging/        private owner lock and recoverable transfer staging
│   │   ├── Profiles/<uuid>/payloads/       private source/diagnostic archives, not attachment history
│   │   ├── StorageMigration/RetainedStages/ abandoned predecessor working copies/stages
│   │   ├── StorageMigration/PiProfiles/<uuid>/public-journal.json public/private publication and retained original
│   │   ├── StorageMigration/PiProfiles/<uuid>/journal.json  publication journal + conversion mappings
│   │   ├── StorageMigration/PiProfiles/<uuid>/source-<uuid>/ retained native source Profile
│   │   └── logs.jsonl                       capped structured diagnostics
│   ├── Caches/
│   │   ├── PiDurableProof/Native/<uuid>/session.sqlite  Opt-in temporary-conversation cache Session; WAL sidecars
│   │   ├── PiDurableProof/NativeFiles/<uuid>/state.sqlite + conversation/shared files  Temporary-conversation filesystem
│   │   ├── PiDurableDiagnostics/<action>/<uuid>/session.sqlite  Upstream storage conformance/benchmarks; removed after each request
│   │   ├── DeviceTemplates/<run UUID>/input.json Debug Simulator-only transient setup input
│   │   ├── DeviceTemplates/<run UUID>/result.json redacted application result
│   │   ├── DeviceTemplates/<run UUID>/preferences-before.plist original changed preferences
│   │   └── ServiceSearchVectors.plist       purgeable service-search embeddings
│   └── ...                                  system-managed framework state
├── Documents/                               visible in Apple Files
│   ├── Repositories/Local/                  complete editable portable Local repository
│   ├── Repositories/<uuid>/                 installed remote snapshots; stable installation folder IDs
│   ├── Repositories/<uuid> Copy <uuid>/     preserved edited snapshots; not connected automatically
│   └── Profiles/<ProfileName>/              complete portable Profile
│       ├── profile.json                 identity and portable storage milestone
│       ├── .ox/state.sqlite             conversations, settings, indexes; DELETE journal
│       ├── .ox/payloads/, .ox/staging/ retained payloads, owner lock and file staging
│       ├── MEMORY.md, SOUL.md               authoritative editable Profile documents
│       ├── skills/<name>/...                authoritative editable user skill packages
│       ├── conversations/<Pi-ID>/...        mutable conversation-owned files and directories
│       ├── <shared folders>/...             mutable Profile-owned files; no required hierarchy
│       └── artifacts/<filename>             retained ordinary predecessor files only
├── Keychain                                 provider and service credentials
└── WKWebsiteDataStore(forIdentifier:)       shared app-wide website state

<configured iCloud container>/
└── Documents/<ProfileName>/              predecessor Profiles; live Pi activation refused

<configured app group>/
├── Library/Preferences/
│   └── app.theme                             canonical app and ShareExtension theme
└── ShareImports/
    ├── Staging/<uuid>/<artifact>             incomplete extension write
    └── Pending/<uuid>/<artifact>             complete copy awaiting import

<developer host Keychain>/
└── service <configured bundle identifier>.dev.llm
    └── account api:<provider-id>             simulator bootstrap API key
```

The ignored `apps/ios/Local.xcconfig` supplies the development team and application
bundle identifier. Build settings, property lists, and entitlements derive the Share
Extension bundle identifier, app group, iCloud container, Keychain service, and
website-data namespace directly from that bundle identifier. Agent skill and conversation
packages use canonical OpenOx type identifiers; the app continues importing the
legacy bundle-derived identifiers.

At startup, `StorageMigrator` removes retired Gemma 4 model artifacts and clears
that provider when it was the saved default.

Primary owners:

Choice, approval, and secret-entry prompts are transient `Conversation` interactions, not new persisted presentation steps. Resolving one returns its answer to the waiting operation without recording a separate prompt receipt. Older prompt steps remain readable but are omitted from conversation display. Model-facing tool results and explicit Always allow policies retain their existing persistence.

- UserDefaults onboarding state — owner: App.swift
- UserDefaults Host access toggle — owner: Platform/Models/HostAccess.swift; app-wide, retained across Profile switches, follows device backup policy, removed with app preferences. Additive Boolean key with no predecessor representation or migration; missing state defaults off, including upgrades from builds that listened automatically.
- UserDefaults import-memory starter count — owner: Client/Features/Conversation/ConversationComposer.swift
- UserDefaults service state — owner: Services/ServiceManager.swift
- UserDefaults model state — owner: Host/ModelProviders/ProviderRegistry.swift
- Keychain credentials — owner: Host/Profile/Credentials.swift
- Retired read-aloud voice preference — retained in UserDefaults and ignored
- App-group theme — current value owners: Theme.swift and ShareExtension; legacy migration owner: Host/Profile/ApplicationStorageMigrator.swift
- Fixed app-storage paths and backup policy — owner: Host/Profile/AppStoragePaths.swift
- Active and saved profiles — owners: Host/Profile/StorageRoot.swift and Host/Profile/ProfileStore.swift
- Profile execution/history/documents — owner: Pi Durable; host-neutral open runtime: packages/agent/src/profile/runtime.ts (`ProfileRuntime`, formerly `OxAgentSession`; persisted formats unchanged); native Session/owner lifetime: Host/Durable/DurableProfileStore.swift; native conversation/presentation: Host/Conversations/Conversation.swift and ConversationManager.swift; application facade: Host/Profile/ProfileRepository.swift. Native type renames do not change persisted ConversationMeta, Turn, RPC, or compatibility-ID formats.
- Compatibility startup/recovery ordering — owner: Host/Profile/StorageMigration.swift
- Profile milestones, conversion, and publication recovery — owner: Host/Profile/ProfileMigrator.swift
- App-wide preferences, catalogs, bookmarks, and schedules — owner: Host/Profile/ApplicationStorageMigrator.swift
- Credential conversion — owner: Host/Profile/CredentialMigrator.swift
- Repository compatibility — owner: Host/Profile/RepositoryMigrator.swift
- Shared stateless conversion and verified-copy helpers — owner: Host/Profile/StorageMigrationSupport.swift
- File metadata — owner: Host/Profile/FileItem.swift
- Folder bookmarks — owner: Services/Native/DeviceFolderStore.swift; records include nullable profileId, with unassigned grants inaccessible until explicitly assigned. ApplicationStorageMigrator stamps predecessor records as unassigned while preserving bookmarks. ProfileMigrator filters retired ios:files attachments at the ProfileRepository metadata boundary; ordinary saves converge them. ApplicationStorageMigrator retires saved Files service references and expands Files source policies into filesystem Action overrides without widening approval. Older readers ignore Profile ownership, and older writes can lose ownership fields; downgrade is not ownership-compatible and requires approval. iOS uses minimal bookmarks, macOS uses security-scoped bookmarks through target-owned adapters. New grant IDs include UUIDs so revocation followed by mounting another folder cannot revive an old binding.
- Mounted repository bindings — owner: Services/Repository/MountedRepositoryStore.swift; device-local, visible/executable only through a grant owned by the active Profile, no source copies or migration. Missing settings mean no connections; malformed or future versions are preserved and block binding mutations. Revoked grants leave unavailable bindings until explicitly disconnected. Older builds retain but do not discover these bindings; mounted-repository functionality is not downgrade-compatible.
- Service repositories — owner: Services/Repository/Repository.swift
- Service-search vector cache — owner: Services/Repository/ServiceSearchIndex.swift
- App log file — owner: Diagnostics/LogFile.swift
- Shared note inbox — owner: Host/Profile/SharedNoteInbox.swift and ShareExtension
- Scheduled skill definitions and run state — owners: Host/Profile/ScheduledSkills.swift and Host/Conversations/ScheduledSkillScheduler.swift
- Developer bootstrap credentials — owner: .agents/skills/setup/scripts/bootstrap.ts
- Debug Simulator device templates — schema/launcher: .agents/skills/setup/scripts/template-schema.ts and template.ts; native startup importer: Development/DeviceTemplate.swift. Control files live under Library/Caches/DeviceTemplates, are excluded from normal startup without explicit launch opt-in, and never become Profiles. Loaded input is removed and private credentials are released after application. Result/previous-preference files are purgeable QA artifacts; evidence copies stay outside Git. Template-created Profiles use ordinary production storage and remain until explicitly removed.

## Profile filesystem

`ProfileFiles` is the Profile file API. Its owned `ProfileFileStore` coordinates file identities, paths, ownership, directories, and a resumable mutation journal. The persisted Pi document retains its historical `ox.workspace` key. File bytes live in the Profile directory, never in SQLite blobs. `DurableFileStore` owns the native lock, staged transfers, pinned reads, verification, and atomic replacement; it composes descriptor-relative `DurableFileDirectory` operations. Normal runtimes inject `ProfileFileBackend` through `fileStorage`, without `FileFiles`, an artifact index, or immutable publication. Memory, soul, and user skills are authoritative physical public files; their predecessor Pi text documents are retired only by trusted preparation. Skill selections remain private Pi documents, and bundled System resources stay app-managed/read-only. Services and granted device folders retain their scoped mounts and permissions.

New files have opaque registrations with an initial extension hint, not artifact paths. Same-path edits retain references. Rename and move retire the old registration and create a new one; old messages show the file as deleted rather than following it. Current paths determine content type. Messages read current contents; copy creates an independent file, and deletion makes references unavailable. Request-owned verified bytes and temporary exports/previews are not persisted attachment versions. Empty directories persist. Relative file paths use `conversations/<Pi-ID>/`; `/` addresses the Profile root. Read-only virtual `conversation.json` and `turns.jsonl` live alongside working files under `conversations/<Pi-ID>/`; these filenames are reserved by the agent filesystem. `history/`, `chats/`, and UUID conversation paths remain unlisted compatibility aliases. No disk transcript is introduced. Existing working-file collisions remain on disk and in the file index; virtual record access reports the conflict without overwriting user bytes. Generic operations cannot mutate conversation roots, mounted roots, database/sidecars, the manifest, hidden staging, or private archives.

Ownership follows destination folders, not references. Conversation deletion records a tombstone before aborting work and removing its files, directories, and proven-owned private archives. Startup retries interrupted deletion. Moved-out shared files survive; forks and other references do not transfer ownership. Mutation intent and a prospective metadata delta commit before filesystem effects; registrations publish only after replay verifies completed replacements/moves. Conflict reconciliation starts from the prior committed registrations, so failed moves do not invalidate references at unchanged source paths. The additive nullable `pendingIndex` contains only file metadata changes and directories, never file bytes. Preflight rejects collisions, links, untracked destinations, and unexpected directory contents. Exact edits reject stale reads. Limits are 200 KiB text, 32 MiB ordinary binary files, and 10,000 Profile file entries. External content is reconciled before filesystem operations and through foreground/presentation refresh. Inventory is bounded, descriptor-pinned, link-safe, and caches hashes using modification/change/size stamps, without tracking inode identity. Observed missing paths retire registrations; recreating that path does not revive them. A delete/recreate between observations is indistinguishable from same-path replacement and is treated as an edit. Recovery conflicts discard interrupted intents and reconcile actual disk state, never reconstruct deleted attachment bytes or blindly overwrite external edits. Simulator evidence does not establish physical-device power-loss durability.

Profile discovery reads manifests only. Startup prepares the selected Profile; inactive Profiles migrate when selected or opened. Current-layout preparation requests only SQLite and its recovery sidecars at the final and interrupted-move locations. File operations reconcile their requested paths or subtrees, preserving unrelated registrations; explicit root listings/searches and recovery can scan the full tree. Native conversation summaries and stable Pi identities are installed without decoding transcripts. Opening, reading history, forking, or executing a conversation awaits its conversion; listing and deleting it do not. Export retains pending source entries and their payloads. Settings defer old-format content until activation. Recovery journals for already-started Profile publications still complete before discovery.

`StorageMigrator` appends `2026-10-10-profile-filesystem`, `2026-10-10-workspace-binding`, and `2026-10-10-profile-files` after the Pi milestone. Trusted preparation inventories predecessor metadata, preserves legacy aliases in the normalized file index, removes artifact entries from the text-document index and binds `ox.filesystem` to `profile-files-v1`. The gate alone resumes the prototype journal format. Ambiguous/shared/saved predecessor files remain Profile-owned. Private generated archives receive conversation ownership only from matching canonical source descriptors and their producing entry IDs; ambiguous producers remain Profile-owned. Existing artifact UI, wire fields, and user-authored helpers are compatibility facades over the filesystem, not another store; artifact helpers are excluded from normal discovery. `2026-10-11-public-profile-files` adds a fingerprint-verified, recoverably published split: public `Documents/Profiles/<name>` and private `Application Support/Profiles/<UUID>`. The private manifest registers the public folder; backups and abandoned stages remain private. Hidden source payloads move to private `payloads/` with legacy aliases; preparation binds `public-profile-files-v1`. The subsequent `2026-10-14-portable-profile` milestone stages and validates private state inside the Profile, stamps the retained predecessor registration to reject older readers, then atomically publishes `.ox/`. A prepared `.ox-stage-<id>` resumes after interruption. The original private database is retained for recovery. `2026-10-14-visible-profile` moves the contents of `.ox` into the Profile root after collision checks and snapshot validation. The source manifest is stamped first to guard older readers and moved last to publish; interrupted moves resume from the remaining source entries. Refresh the source inventory after validation closes SQLite, because checkpointing can remove WAL/SHM sidecars before publication. The empty `.ox` directory is removed. `2026-10-14-internal-profile-state` subsequently keeps `profile.json` at the root and moves `state.sqlite`, `payloads/`, and `staging/` under `.ox/`. It checks collisions and validates state before stamping the root manifest, which guards older readers; partial moves resume at the new milestone. Portable Profiles open in place from Files; SQLite uses DELETE journaling without a lifetime file ownership lock. Simultaneous editing across devices is unsupported. Cloud upload completion and third-party provider semantics require device verification. A full file-manager UI remains deferred; current viewers resolve nested Profile files and refresh deleted references.

Conversation export verifies live metadata and bytes, maps references to current file types, and includes referenced local dependencies in the existing portable package format. Import first creates an empty conversation, publishes files directly into its final working directory, rewrites references and sibling dependencies, then populates turns. Failures attempt conversation-owned cleanup and log cleanup failures; this is not an atomic package transaction. Retained migration source backups remain private recovery material outside the active Profile, not attachment history.

## Pi Durable Sessions and upstream diagnostics

The legacy cache and physical-publication formats below are predecessor representations consumed through `StorageMigrator`; ordinary temporary conversations now use the same filesystem in their isolated `NativeFiles` cache. SQLite-blob caches remain explicit diagnostic fixtures only.

`DurableConversationController` owns opt-in temporary-conversation Sessions under
`Library/Caches/PiDurableProof/Native/<uuid>/`. Several temporary conversations share each
Session. These private caches are purgeable, outside backup/sync/export, and never
opened by normal startup or Profile activation. They have no credentials or
website state. Native Sessions add `ox.profile`/`ox.file` documents and
`ox.chat` v1 conversation metadata plus `ox_blobs`/`ox_blob_chunks` for bounded
binary content. Pi conversation records are authoritative. `ox.chat` contains only
the external Ox UUID; a disposable UUID-to-Pi-ID lookup is rebuilt from Pi records
on open. No separate `ox.chats` registry is created or consulted; unconsumed cache
documents are left untouched, without converting user Profile data.
Blob commits precede document-reference commits; orphan reclamation is serialized
against readers/writers. This is not one combined document/blob transaction.
Submitted messages, contextual snapshots, model replies and native diagnostics
can be present: these are private user-owned scratch data, not anonymous fixtures.
The controller handles temporary conversations only; normal Profile activation never opens these caches. Ordinary temporary conversations now attach automatically, while the explicit launch flag retains a chosen QA cache identity.
An explicit launch with `OX_DURABLE_TEMPORARY_SESSION=<UUID>` allows an idle conversation
switched to temporary in the actual UI to attach to `NativeFiles`, including
Release builds on physical devices. Diagnostic RPCs remain DEBUG Simulator-only.
Admission waits for attachment and rejects preparation failure without selecting
the legacy loop. Preparing/attached conversations cannot become persisted. The test
skill's actual UI replay verifies reasoning, Markdown, native tools, Stop and
history retained across process reopen. Its stopped-process cache copies include
WAL/SHM and are private diagnostics, never Profile export/import or activation.

`DurableStorageController` owns fresh
`PiDurableDiagnostics/<storageConformance|storageBenchmark>/<uuid>/` fixtures for
published Pi storage conformance and benchmarks only. They use the native SQLite
facade without an Ox Session, Harness, scheduler, Profile content or provider
requests. One read dataset serves its warmup/retained sweeps; each write sample
and conformance case uses a separate database. The controller serializes requests
and refuses stale fixture reuse. SQLite closes before runtime disposal and
fixture/WAL removal on success/error. Abrupt termination or failed cleanup may
leave purgeable synthetic caches, never adopted or reopened by the runner.
Reports and whole-app process gauges stay outside the repository under `/tmp`.

Custom mock proofs, effect receipts, fault-injection hooks, artifact/security
fixtures, conversion/package experiments and the agent-overhead benchmark have
been removed. Existing retired cache directories remain untouched and ignored;
no production Profile format or compatibility milestone is changed.

### Predecessor physical files and conversation projections

`NativeFiles` uses `state.sqlite` and flat ordinary files in
`artifacts/`, including UTF-8 text artifacts. The native `DurableFileStore`
acquires the descriptor-relative `.owner` lock **before** SQLite opens and retains
it until database close. Files/directories reject links; published files are
single-link regular files. Private transfer staging, `.owner`, WAL and SHM are
implementation details, not independent authorities. Transfers use 128 KiB chunks;
reads still assemble a whole bounded file. Limits are 200 KiB text, 32 MiB binary,
10,000 indexed files, four native transfer handles and 240 UTF-8 bytes per basename.
Publication is write-once, digest-checked and flushed; metadata commits follow
physical publication. Failure between them can retain unreferenced physical bytes.
Logical removal hides the index entry but retains historical metadata/bytes.
Overwrite, edit, filename reuse and physical-backend orphan collection are refused.
`F_FULLFSYNC` has an explicit supported-platform fallback; simulator passes do not
establish physical-device power-loss durability.

Pi's nine tables own history, documents and execution. `ox.profile` v1 provides
an index/integrity binding, not a competing manifest. `ox.file` v1 holds UTF-8
memory/soul/skill documents. `ox.filesystem` v1 binds the backend as
`artifact-files-v1` or explicit `fixture-blobs-v1`; implicit transitions are refused.
`ox.artifact` v1 holds `{path,size,sha256,binary,saved}` without artifact bytes.
The Profile document kinds checkpoint every 32 ordinary changes.
`ox.conversation.presentation`, `.favorite` and `.read` v1 are conversation-scoped
latest projections. Title/visibility fork current; favorite/read fork initial.
Qualified `(profileID,conversationID)` references and bound cursors route full
fork-aware scrollback separately from active model context. Read-only virtual
`conversations/<Pi-ID>/metadata` and `history` are generated from Pi, never disk transcripts. The native UUID projection uses `conversations/<uuid>/conversation.json` and `turns.jsonl`. Old `chats/` virtual paths and `ox.chat` calls remain compatibility aliases for user-authored code. `StorageMigrator` rewrites stored `ox.chat.start` and `ox.chat.delete` approval keys to `ox.conversation.start` and `ox.conversation.delete` before policy consumers initialize; existing destination policies win collisions, and subsequent launches are no-ops. Predecessor disk paths, document kinds, and UUID binding keys are unchanged.
Physical image results use `oxAttachment`/`oxProfileID`, not image Base64 in history.
Temporary native routing still retains explicit `ox.chat` UUID compatibility.
Portable Profiles activate Pi after the storage gate at their selected folder. No simultaneous cross-device editing or raw active-database export is supported. Native UI testing uses direct simulator interaction; Host RPC still requires authorized VPN ingress without loopback exceptions.

Profile export captures a complete, closed snapshot, validates its SHA-256 inventory, and returns a directory containing visible files plus `profile.json`, `.ox/state.sqlite`, and `.ox/payloads`. The format-1 ZIP is an internal temporary encoding, not the exported document. Capture refuses pending tasks, submissions, and file changes, closes/checkpoints the runtime, and coordinates the folder read without a file ownership lock. Exports retain the Profile identity and are bounded to 128 MiB and 10,000 entries. Credentials, folder grants, schedules, app settings, staging, temporary conversations, and migration journals are excluded. Files chooses the destination; a completed save does not establish completed iCloud upload. Open Existing opens the exported directory in place; there is no separate Import action. Create accepts a Files-selected parent and publishes a verified fresh Profile there. Move first closes the source, verifies a complete copy including empty directories, switches its bookmark, and retains the original until explicit removal confirmation. Removal checks the original inventory again; changed originals remain untouched. Missing remembered folders stay unavailable and can be reconnected only to the same Profile identity; they do not silently select another copy or create an empty replacement. Optional bookmark display names are additive; older records remain readable.

`ProfileMigrator.stageDurableProfile` builds an unpublished portable Profile from the last native representation, preserving source fingerprints, link rejection, and Profile publication journals. Initial native-to-Pi publication still materializes and copies the complete legacy source; deferred decoding is not lazy first-upgrade iCloud downloading. Earlier native milestones still run on a verified working copy. Metadata, transcripts, and optional checkpoints are archived in streaming 128 KiB buffers and referenced by ordinary `ox.native.conversation`, `ox.native.transcript`, and `ox.native.context` entries. No per-conversation progress document, status, or journal is stored.

`ConversationMigrator` decodes one archived native entity when accessed. It retains checkpoint validation, legacy effect/purpose handling, bounded oversized invocation references, unavailable-attachment notices, and transcript recovery for stale checkpoints. Native payload publication precedes one atomic Pi commit containing canonical entries, the normal `ox.native.metadata` source entry, the active-context reset, and owned payload registrations. Canonical entries take precedence over the retained raw source. In-flight conversion is deduplicated in memory and joined before close; failures before publication leave the source retryable. Existing deletion tombstones reject publication after deletion and prevent resurrection.
The shared normalized installer has no legacy decoder or model/tool execution.
Conversation drafts are spooled one at a time to `.migration-conversations/` inside the unpublished stage, then loaded and verified individually by the installer. The spool is removed before the staged manifest is stamped; failed stages retain it for diagnosis. Native runtime commands pass JSON as data to a fixed JavaScript function rather than compiling each payload as script source.
Pi entries retain the full ledger and application payloads; self-head checkpoints
retain compacted active context separately. `ox.conversation.metadata` v1 stores
non-identity application settings, with latest history, current forks and bounded
checkpoints. Source-key mappings are returned to the migrator, not stored in a
runtime registry. Physical artifacts are digest-checked and flushed before Pi
metadata commits. The installer closes SQLite and its artifact owner before the
staged manifest receives `2026-10-15-lazy-conversations`, after preparing the final `.ox/` layout. Earlier Pi milestones remain immutable supported predecessors; current Profiles advance to the appended milestone before activation. Older readers reject this milestone without opening its database; this is an explicit downgrade incompatibility requiring approval before release. Legacy milestones run on a fingerprint-verified `.pi-source-work-<uuid>` copy rather than the original Profile. A prepared publication journal retains conversion mappings and original source fingerprints; the untouched source moves to a private retained backup before stage publication. The working copy is removed after publication; failed working copies remain hidden and are never adopted implicitly. Recovery runs before Profile enumeration and completes interrupted publication before consumers open. Failed unjournaled stages are retained for diagnosis and never reused implicitly. Fresh Profiles install and validate an empty dormant Pi database before publishing their manifest.

The predecessor Pi Profile was `profile.json`, `state.sqlite`, and immutable files at `artifacts/<filename>`. `profile.json` alone owns identity, creation date, and migration milestone; database bindings are integrity checks. Production identity is `(Profile ID, Pi conversation ID)`. Native UUIDs are deterministic presentation projections, not a registry. Source UUID conversion mappings remain in `StorageMigrator` journals.

`ox.native.presentation` entries retain immutable current rich UI decorations without contributing model context. `ox.conversation.metadata` stores `nativeProviderID` for credential routing and native-only reasoning options; Pi AgentDoc owns model/thinking choices. Canonical Pi models override decoration text/calls/results. New migration entries retain exact source JSON through `{path,size,sha256}` file references; older inline `sourceJSON` entries remain readable without rewriting. Runtime presentation never decodes the source archive. Legacy invocation arguments and results larger than 16 KiB use `oxPayload: {format:1,source,offset,length}` plus a bounded omission notice instead of embedding their full bytes. Existing archive descriptors remain available to migration readers. These content-addressed immutable `artifacts/payload-<sha256>.json` archives are committed as `ox.artifact` metadata without entering the visible `ox.profile` file index. They share the native artifact owner, are retained with history, and have no automatic reclamation. `ox.output.read` reads only conversation-local captured JavaScript output; model-facing archive retrieval is retired. Existing archives and migration readers are retained without a storage-format change. Publication and streaming digest verification precede migration references; no raw payload SQL blobs are introduced. New Actions do not create diagnostic archives. Whole skill package and selection changes use one Pi document/index commit. File edits/renames choose new immutable filenames and retain prior metadata/bytes.

New native Action traces retain bounded JSON previews rather than complete inner results. `Invocation.preview` records argument, result, and purpose clipping; optional `sources` retains bounded query/domain/link metadata for source chips. `Execution.invocationTrace` counts retained and omitted calls and preview bytes. Each execution retains at most 256 Actions and a 64 KiB combined preview/source budget, with 8 KiB arguments and 4 KiB results per call. Preview traversal also limits depth, nodes, keys, and array items. Purpose/error text is limited to 500 Unicode scalars. `ThinkingTrace.omittedInvocations` projects omissions into the inspector. These optional fields are additive; older records, canonical Pi context, source archives, and artifact effects are unchanged. Recording is synchronous and nonthrowing; approvals, Actions, and JavaScript receive complete original values. Temporary conversations use the same preview policy. Actual artifact effects keep their existing byte-retention policy; diagnostic previews do not publish artifacts.

Pi scheduling is global to a Session. Before any progress, every recovered task/submission conversation must have its qualified native route and saved model/transport configuration installed. Recovery uses existing durable submissions and waits for both settlement and committed native-event delivery; it never resubmits user input. Cold native tools hydrate from actual Pi task/assistant/context proof without model re-stream or native hook replay. Unsafe interrupted tool intents are not rerun. Storage admission failure can poison a Pi Session even after SQLite rolls back: report failure and explicitly close/reacquire; never blindly retry effects through the failed Session.

Provider media uses request-owned verified bytes, and preview/share/HTML sibling readers use pinned bytes or owned immutable snapshots. An ordinary file URL is routing metadata, not snapshot proof. No live SQLite sync, external in-place edits, unsafe artifact garbage collection, or adoption of old debug caches is authorized. Native migration/normal-conversation/process-recovery evidence is simulator-specific; released-predecessor and physical-power-loss acceptance remain separate gates.

## Compatibility gate

`StorageMigrator` coordinates startup and recovery. App-wide structural
migrations run before the Host and its storage consumers are constructed. Host
preparation then validates application storage, migrates the selected Profile,
and prepares the Local service repository before conversations, service discovery, or
search indexing load persisted state. Selecting or opening another Profile also
migrates it before publishing its `ProfileScope`.

`ProfileMigrator` owns ordered Profile milestones and publication recovery;
`ApplicationStorageMigrator`, `CredentialMigrator`, and `RepositoryMigrator`
own their scoped transforms. `StorageMigrationSupport` shares stateless helpers.
The coordinator preserves prerequisite ordering. Service-repository repair remains
structurally detected because the old Local layouts predate a shared application
schema marker. Profile milestone identifiers are immutable after any build can
stamp them. Unknown Profile versions and unsuccessful migrations fail closed at
the loading screen rather than allowing consumers to interpret incompatible
data; an unknown version specifically directs the user to the Ox build that last
opened the Profile or a newer one.

Local repository and scheduled-skill preparation failures isolate those resources
instead of blocking a compatible Profile. Normal resource access and writes remain
gated; Local services/skills are excluded and schedules neither execute nor accept
edits. The Host retries through `StorageMigrator` with backoff capped at five minutes
while foregrounded, pauses in background, and retries on later launches and foreground
activation. Successful recovery reloads the catalog or activates scheduling without
requiring user action. Incompatible data is retained, never reset or replaced with a
stale snapshot to force recovery. Resource readiness is reconstructed, not persisted
in a separate status file.

Repository configuration keeps format version 1. Local is always enabled; new
builds ignore and stop writing the legacy `localEnabled` field, and older builds
default it to true when it is absent.

Repository packages live in `Documents/Repositories`, are user-owned, and remain eligible for device backup. `RepositoryMigrator` moves predecessor Local and UUID remote folders before repository preparation; it verifies source/destination file fingerprints, retains hidden Git state and empty directories through whole-folder moves, and refuses destination collisions. Development snapshots and predecessor migration backups remain private. Missing Local manifests fail without recreating a manifest over existing files. Remote origins, enablement, resolutions, and optional snapshot inventories remain in `service-repositories.json` format 1. Inventories include ordinary files and directories; a missing baseline is treated conservatively as potentially edited. Sync refuses changed snapshots unless the user chooses Keep Copy and Sync in Settings, which preserves a verified complete copy in Repositories before replacement. Changes during downloading or publication abort replacement. Startup restores interrupted snapshot backups when the active folder is missing, or preserves them as visible copies when a new snapshot is already present. Disconnect retains repository files; deletion is performed explicitly in Files. Repository settings reload after browsing or foregrounding.

Older builds do not discover the new paths and can recreate stale private repositories. This location change is not downgrade-compatible; actual predecessor/changed-build verification and maintainer approval are required before release. Returning to the changed build refuses conflicting private/public folders rather than merging or overwriting them.

Remote MCP connections are Local services at `Documents/Repositories/Local/mcp/<id>/service.json`.
The id is derived from the endpoint host, with a numeric suffix for collisions,
and is the runtime service domain. Creating or migrating a connection selects Local
for any same-id conflict. Local preparation converts the legacy
`remoteMCPServers` (and its older `remoteMCPEndpoints` form) into these manifests,
renames `savedServices` and `actionApprovalPolicies` references from the legacy
`mcp.<endpoint hash>` domain, then deletes the preference. Conversation attachments
keep their stored legacy domain until the conversation resolves its services, which
rewrites it to the Local id. Older builds show migrated connections as repository
MCP definitions that they cannot update.

## Shared preferences

The app-group `app.theme` value is the single theme source shared by the app and
ShareExtension. On first launch after upgrading, the app copies a legacy standard
UserDefaults value into the app group and removes the legacy value.

Application migration converts the legacy `autoApproveActions` allow-list and
`autoApproveAll` preference into `actionApprovalPolicies`. The versioned JSON value
stores an optional global override plus optional source and Action overrides. No
global override means Automatic: registered built-in Ox Actions default to Allow
except deletion, while unknown Actions default to Ask. Service and device Actions
use their declared defaults. The
version-one Ask default migrates to Automatic; explicit source and Action policies
remain unchanged. Missing state uses Automatic, while malformed and unknown future
formats fail closed to Ask without discarding the stored bytes. Migration removes standing
approvals for retired Action identifiers, including `ox.app.inspect`, every
`ios:browser:*` Action, and the legacy Browser attachment Action. It does not
transfer approval to replacement Actions; `ox.web.browser.*` functions follow
the current built-in Action defaults and explicit user overrides.

## Profiles

A profile is a directory whose `profile.json` contains its stable UUID, creation
date, and schema milestone. Its folder name is the user-visible name. The folder
is the unit Ox creates, renames, duplicates, moves, and deletes.

Exactly one profile is active. `StorageRoot` publishes an immutable `ProfileScope`
for asynchronous operations; work never resolves a path through a mutable global
after it begins. The active UUID is device-local and persists in
`storage.activeProfile`.

Storage owners discover and persist only `profile.json` and
`storage.activeProfile`.

Ox automatically discovers valid profiles that are immediate children of its
local and iCloud Documents directories. It does not scan elsewhere in Files.
Bookmarks for explicitly opened folders are persisted in `external-profiles.json`,
including local selections so reopening a copied Profile consistently selects the
chosen folder. Selected bookmarks take precedence over discovered copies of the
same identity. Stale bookmarks are renewed after successful resolution.

Profiles can use three storage locations:

- Local profiles are immediate children of the app's Documents directory. They are
  visible in Files and excluded from iCloud device backup.
- iCloud profiles are immediate children of the app's public iCloud Documents
  directory. They have the same internal layout and may be evicted or changed by
  another device.
- External profiles remain in a user-selected Files folder outside Ox's local and
  iCloud Documents directories. Ox holds the folder's security scope while it
  is registered and reads and writes the profile in place. Closing an external
  profile removes its bookmark without deleting the folder.

Saved profiles deduplicate by profile UUID. If the active profile is unavailable,
Ox selects another saved profile or creates a new local profile named `Default`.
Creating a named profile stages and validates the complete directory before
installing it. Moving a
managed profile between local and iCloud storage uses coordinated iCloud operations;
a git working tree never lives inside a Profile. Opened profiles are renamed and
moved in Files rather than by Ox.

`ProfileRepository` is the sole application writer for Profile content. It serializes
filesystem coordination per immutable scope and rejects stale results after a
Profile switch. While foregrounded, file presentation reconciles external changes
to soul, memory, skills, visible artifacts, and conversation summaries. Hydrated conversations
remain authoritative in memory and are not blindly replaced.

Multi-writer conflict preservation for a conversation simultaneously edited on more than
one device remains undefined. Current ordering guarantees apply to one running
app's writes.

## Conversations

Each persisted conversation owns one directory:

- `chat.json` contains `ConversationMeta` in the predecessor disk format: schema version, identity, dates, title,
  favorite state, one provider/model/thinking `ModelSelection`, MonoRepository hash, attached
  services, sidebar preview, and whether the latest completed response is
  unread. Conversations created by a scheduled skill execution also retain that
  schedule's identifier so clients can group them separately from recent conversations.
- `turns.jsonl` contains one semantic `Turn` per line. Stable IDs and tagged
  outcomes represent user turns, agent generations, reasoning, text, executions,
  prompts, tool calls, and effects. UI blocks and provider wire messages are
  derived projections, not additional persisted stores. A skill-submitted user
  turn retains the expanded provider intent plus a skill snapshot and trailing
  user argument for compact transcript projection.
- `context.json` normally exists only after compaction and contains the provider-neutral
  agent context checkpoint, provider metadata required for continuation,
  transcript boundary and digests, and compaction accounting. Before compaction,
  the complete current context is projected from `turns.jsonl`. Hydration accepts
  a compacted checkpoint only when its schema and digests match the transcript;
  otherwise transcript projection recovers context. Migration removes a redundant
  legacy checkpoint only after its complete transcript decodes; if any historical
  turn is unreadable, the checkpoint is retained and ignored rather than risking
  destructive cleanup.

Completed generations and agent turns are persistence checkpoints. Streaming
presentation does not write every token. A save writes the transcript, writes or
removes the optional compacted context, then atomically publishes metadata, so
the sidebar never advances beyond the durable payload.

`ConversationManager` retains the selected conversation and up to four inactive conversations in memory.
Each conversation has one save pump: one immutable request may be in flight, and newer
complete state replaces one pending-latest slot. Exact save IDs prevent an old
completion from acknowledging newer state.

Hydrating interrupted work converts running turns, executions, and invocations,
plus pending prompts, to terminal cancelled or failed states and persists the
repair. Backgrounding flushes all conversations while active workers continue under
their execution leases. Submissions not yet posted to the transcript are not
durable.

A temporary conversation has no directory, summary, persistence callback, or
notification preview. It is discarded when left or when the process ends and
cannot mutate Profile-owned content.

The Browser-to-built-in-function migration removes the retired `ios:browser`
domain from persisted conversation attachments. Existing Browser inspector transcript
rows remain readable and resolve to the intrinsic Browser runtime.

Conversation sharing creates a transient `.chat` ZIP package whose `chat.json` stores
the package and transcript schema versions, source metadata, content counts,
service-domain disclosure, and SHA-256 inventory. `turns.jsonl` retains the
semantic transcript; `context.json` is included only for compacted conversations so
continuation state is not lost. Legacy packages with redundant uncompacted
context remain readable and normalize to transcript-only storage on import. The
package also contains transcript- or
checkpoint-referenced artifacts and supported sibling media dependencies.
Import validates ZIP paths, compression, CRCs, declared hashes, transcript
state, checkpoint digests, compaction completeness, and artifact references
before presentation. Confirmation stages a new conversation identity and collision-safe
artifact filenames, rewrites both transcript and checkpoint references, rebuilds
checkpoint digests, and installs the files as one repository transaction. It
does not restore provider selection, service attachments, pending work, or any
state outside the package.

Legacy conversation and artifact layouts migrate through retry-safe Profile schema
milestones. A milestone is stamped only after every required operation succeeds;
an interrupted migration preserves a recoverable source or equivalent
destination and resumes on the next activation.

## Predecessor artifacts

This section records the native representation preceding Pi and the filesystem. It is not the current runtime storage model.

`artifacts/` is a flat directory of ordinary files plus a hidden `.saved.json`
index containing the basenames the user saved. The case-insensitive basename is
the stable identity; type, MIME type, size, and dates are derived from the file.
Imports sanitize names and resolve collisions with numbered suffixes. Text is
limited to 200 KB, other files to 32 MB, and imported images are bounded before
storage. File rename and deletion keep the saved index aligned with the
user-visible file operation.

Conversations persist live filename references. Editing changes what an old conversation opens.
Deleting or externally renaming a file leaves a missing reference. Profile-owned
renames rewrite persisted conversation references and canonicalize later saves from
already-hydrated conversations.

Remote MCP image and embedded-resource tool content is imported into the active
Profile before it is presented in conversation. The MCP server retains its source copy;
Ox stores a collision-safe artifact file and the conversation stores the same live
filename reference used by locally created artifacts. Local, iCloud, and
external Profile locations therefore keep their existing artifact persistence
and synchronization behavior.

Browser full-page PDF exports remain transient unless the action supplies an
artifact filename. Named exports use the same validation, collision-safe import
path, Profile ownership, live conversation reference, and synchronization behavior as
other PDF artifact imports.

The model accesses files only through `execute` → `ox.fs.*`. Agent-owned mount routing, pagination, exact-edit preflight/diffs, serialized mutations, and bounded traversal/search live in `packages/agent/src/core/filesystem.ts`. iOS supplies operation-scoped backing-store capabilities and retains `StorageMigrator` aliases, native approval, source permissions, Files grants, media conversion, and immutable physical publication. Read/write/edit inputs follow pinned Pi, with optional `purpose`; reads return at most 2,000 lines or 50 KiB with continuation offsets. No persisted path, encoding, milestone, or retention policy changes for this routing consolidation.

The agent sees a virtual filesystem containing `MEMORY.md`, `SOUL.md`,
`artifacts/<filename>`, persisted conversation history, and source-aware skill and service
mounts:

```text
skills/<name>/
├── SKILL.md                                    resolved package instructions
├── references/<path>                           optional nested UTF-8 references
└── scripts/<path>.js                           optional Ox VM helpers

services/
└── <kind>/<id>/
    ├── service.json                            read-only except Local
    └── ...                                      visible and editable only for Local

conversations/
└── <conversation-uuid>/
    ├── conversation.json                                read-only, current or stored metadata
    └── turns.jsonl                              read-only, current or stored transcript
```

Bundled System packages are owned by `packages/agent/skills/` and exported through
the same skills catalog and `skills/<name>/SKILL.md` namespace as other packages.
They are available before attachment and in temporary conversations, remain read-only,
and copy into a distinct-name Profile package for customization. Relative resource
links preserve customization; custom copies do not authorize System-gated effects.
The trusted runtime supplies scoped packages and activation requirements to hosts.
No guidance bundle, generated inventory, or separate workflow mount remains.
`ProfileMigrator.legacyWorkflowLocation` redirects old `guidance/<name>/guide.md`
and reference/helper paths to canonical skills without exposing another root.
Only the five known names are accepted; aliases have the same read-only permission
and activation behavior. Persisted formats and captured historical snapshots remain
unchanged; non-System snapshots cannot override a reserved System path or policy.

The mount resolves permissions from the selected source, never frontmatter.
System, enabled repository, and active Profile packages share one catalog before
service attachment. Duplicate non-System names require a Profile source selection;
System packages always own their reserved names. Untrusted packages cannot shadow
System names or grant mutation permissions. Local packages are writable;
installed and bundled packages are read-only. Every selected service exposes
its manifest for discovery. Bundled, Remote, and Development source files remain
hidden and read-only; Local exposes its additional source files at the same
`services/<kind>/<id>/` path. Repository host paths, markers,
`chats/<chat-uuid>/context.json`, and unrelated secret contents are not
addressable. The conversation mount returns a current snapshot for loaded persisted conversations and the saved
files for unloaded conversations. `ProfileRepository` encodes both with the same metadata
and transcript format; reads do not write snapshots or change storage checkpoints.
Temporary conversations remain excluded. `ox.conversation.start` creates a normal persisted conversation
without selecting it, and its ID is immediately readable through this mount.
Built-in JavaScript guidance is readable as source, but is not installed,
importable, or resolvable from a service action runtime. `StorageMigrator` owns
read-only compatibility snapshots for old `skills/<system-name>/` paths, using
the current guidance and its resources. Existing run snapshots take precedence;
frozen invocations, schedules, historical migrations, user copies, and transcript
bytes are unchanged. No persisted format or milestone changes for this move.
Retired workflows are excluded from catalog/root skill listings. Named Pi system
sections replace the old `ox` section through Pi's normal transcript patching;
memory remains frozen per conversation and turn-state facts remain per-message.
Unscoped root grep excludes conversation files, while an explicit `conversations` path searches
JSONL records with a separate bounded byte budget and match-centered excerpts.
Reads and searches are bounded; writes are atomic; writes and edits to the same
file are serialized; edits require exact non-overlapping matches.

User-selected Files folders appear separately as `files/<grant-id>/...` after
the grant belongs to the conversation's Profile; no Files service is required. Security-scoped bookmarks live in
`Application Support/device-folder-grants.json`, outside every Profile and outside
backup. Each operation rejects traversal and symbolic links. `ox.vision.analyze` reads
bounded image snapshots from these folders for on-device OCR and classification.
`ox.fs.attach` explicitly attaches file byte snapshots through the existing
immutable native media publication path; binary format support depends on the selected
provider, and original external paths are never durable
attachment references. Saved conversations retain published bytes in their Profile;
temporary conversations use their purgeable Session. No new storage format is introduced.
Writes, edits, and deletes require a valid folder grant owned by the requesting Profile. Built-in
writes and edits default to Allow, while delete defaults to Ask. File import
and rename default to Allow; artifact and filesystem deletion default to Ask.

HTML artifacts remain ordinary UTF-8 files. Presentation creates a fresh
non-persistent WebKit store and reads the current artifact plus bounded sibling
media through `ox-artifact:` URLs. Maps use `<ox-map>` and `<ox-marker>`. The
renderer itself does not add durable website state. Canvas service calls use the
Host's existing service accounts. Canvas owns no conversation, attachment list, or permission
store. Service-produced files live in a presentation-owned temporary directory,
are bounded by the Host, and are deleted on close.

Shoveler cards persist an optional artifact filename in the conversation transcript.
Opening a card resolves that reference in the active Profile and uses the same
native artifact preview as other conversation artifact references. Conversation package export
includes artifacts referenced only by Shoveler cards.

Video and image widgets persist a public HTTPS source or an artifact filename in
the conversation transcript. File-backed widgets participate in rename, package export,
and collision rewriting like other artifact references. Image widgets add an
`image` execution effect and content item using the same tagged source encoding as
video; existing records are unchanged and require no transform. Older builds cannot
read new image effects. Remote image bytes are credential-free, bounded, held only
for presentation, and never published as artifacts or model attachments.

The Share extension converts user-selected shared text into a Markdown file in
the app-group staging directory, then atomically moves its directory to Pending.
The app reads only complete Pending directories on activation, imports each file
through the normal collision-safe artifact path, and removes a directory only
after its artifact succeeds. Failed copies remain pending for a later retry.

## Soul, memory, and skills

`SOUL.md` and `MEMORY.md` are plain UTF-8 text. They are seeded when absent,
cached for presentation, and written atomically. Both reload after Profile switches;
only `SOUL.md` reloads after relevant external changes. Each conversation snapshots the
loaded memory into its system prompt so later memory changes do not invalidate the
conversation's prompt cache. An existing unreadable or cloud-evicted file is not overwritten.
The default SOUL seed is defined in TypeScript and generated into the signed app's
`PiDurable.bundle/default-soul.md`. Native loading requests it only after confirming
that the Profile document is absent; missing resources fail without seeding empty
content. Existing SOUL/MEMORY documents and their persisted representation are unchanged.

Each skill package contains `SKILL.md` and optional nested UTF-8 files under
`references/` and JavaScript helpers under `scripts/`. Names use lowercase kebab-case;
frontmatter includes the matching name, description, and optional comma-separated
service dependencies. Packages are limited to 64 files and 512 KiB. Symlinks and
traversal are rejected. Profile packages live at `skills/<name>/`; repository
packages live at the repository root `skills/<name>/` and are declared in version 3
`repository.json`. Services no longer declare or contain skills.

`skill-selections.json` in each Profile is version 1, with `sources` mapping skill
names to stable owner IDs (`user` or `repository:<id>`). Absent selection resolves a
unique name automatically. A missing selected source remains unresolved. Source
labels and writable state are derived from the current catalog. Selection metadata
syncs and exports with the Profile. Packages read during a run are frozen together
with all references and helpers for that run.

Customizing makes an independent complete Profile copy. Sharing into Local copies
the complete package for direct editing. `.skill` exports contain every supported
resource and strip source ownership; imports create a Profile package after user
confirmation. The archive itself is transient.

The `2026-09-24-repository-skills` Profile milestone normalizes old virtual paths
and API names in authored instructions and renames reserved user names to
`user-<name>`, failing on unequal collisions. Transcript bytes remain unchanged.
Repository version 2 conversion preserves original manifests and packages in a
sibling `.<directory>-repository-v2-backup` journal. The journal is retained for
recovery. Conversion operates on the current source files without reading or
updating retained Git metadata. Invalid legacy drafts defer migration with
originals retained. Future versions fail closed.
The existing `service-repositories` disk paths, configuration filename, and PAT
Keychain account remain stable despite the product/API rename to Repository.

The `2026-09-25-import-memory` Profile milestone reserves `import-memory` for a
bundled system skill. An existing Profile skill with that name moves to
`user-import-memory`, preserving its package resources and moving an explicit
user source selection to the new name. An unequal destination collision stops
the migration without replacing either package.

The `2026-09-27-outcome-skills` Profile milestone reserves `evolve` and
`visualize`, replacing the bundled `manage-services` and `manage-artifacts`
packages. Existing Profile skills with either new name move to `user-<name>`
with resources and explicit user source selections preserved. Unequal destination
collisions stop migration without replacing either package. Existing repository
packages using a newly reserved name fail catalog validation with their files
untouched; their author must rename them. Saved invocations and schedules keep
their frozen packages, and transcript bytes remain unchanged.

The `2026-09-28-provider-skill` Profile milestone reserves `manage-providers` for
on-device provider/model catalog management. An existing Profile package moves
to `user-manage-providers`, preserving its resources and explicit user source
selection. Unequal destination collisions stop migration with both packages
intact. Repository packages using the reserved name must be renamed by their
author; frozen invocations, schedules, and transcripts remain unchanged. Provider
catalog storage and credential ownership are unchanged.

`Application Support/scheduled-skills.json` is a version 2 device-owned document
containing at most 100 scheduled invocations. Each record binds to one Profile UUID
and stores a frozen complete skill-package snapshot, optional argument, one-time/daily/weekly
recurrence, time zone, next occurrence, enabled state, and bounded last-run outcome
with its result conversation UUID. The file is prepared and validated by `StorageMigrator` when schedules load;
unknown versions and malformed or duplicate records disable scheduling and edits,
retain the file, and defer to automatic recovery without blocking ordinary conversations.
It follows Application Support's normal device-backup policy and never syncs through
the Profile, preventing one iCloud Profile from executing on several devices.

Only schedules bound to the active Profile execute. A due record for another
Profile advances once as a failed occurrence and notifies when authorized. Each run
uses the saved skill snapshot, creates an unselected persisted conversation in the bound
Profile, and advances to the next future occurrence after completion, failure, or
cancellation. Missed recurring occurrences coalesce into one run rather than being
replayed. One-time schedules disable after their occurrence. iOS background
processing is best-effort and may begin after the stored next-occurrence date.

Opening a Profile uses the Files folder picker. Ox validates the selected
directory's `profile.json`, saves a security-scoped bookmark, and activates the
directory in place. The profile retains its UUID and is not copied, packaged, or
merged. Closing it removes the saved bookmark and leaves every file untouched.

## Service repositories

`OxServices.bundle` is the built-in service repository in the signed app bundle.
Service manifests and actions are read directly from the app without a Git
repository or Application Support copy. Web favicon bytes are not packaged:
each generated manifest stores an `https://openox.ai/assets/services/<domain>/favicon.png`
URL backed by a private S3 bucket through CloudFront. The app downloads bounded
PNG or JPEG data without cookies or credential storage and keeps successful
images in memory for the process lifetime. Every service source has a top-level
`repository.json` with a string array of canonical `<kind>:<identity>` service IDs.
The kind and relative path are derived from the ID; for example,
`web:example.com` resolves to `web/example.com`.

`Library/Application Support/service-repositories.json` stores which read-only
repositories are enabled and the user's whole-service choice for each conflict.
Public HTTPS Git repositories are cloned into temporary staging directories.
After validation, their `.git` metadata is removed and the resulting `HEAD`
snapshot replaces `service-repositories/<uuid>/`. These snapshots are
reproducible app infrastructure outside Profiles, Files, and iCloud, and are
excluded from device backup. Removing a repository deletes its snapshot and
saved conflict choices without touching website data.

The editable Local repository always exists at `service-repositories/local/`.
It can be disabled in the active catalog but cannot be removed. Local edits persist
directly without Git initialization, commits, checkout, or a separate Save step.
Existing `.git` metadata is retained untouched for external recovery, but is not
read or updated by Ox; the current source files are authoritative, including when
an older build left a detached checkout. There is no built-in version history or
automatic rollback. The repository never introduces another virtual directory: its selected services
resolve directly into `services/<kind>/<id>/`. Local file writes are atomic and
enforce write permissions, path containment, symbolic-link rejection, and the
general file size limit without validating service contents. Local drafts
may contain incomplete, missing, or inconsistent service files across app restarts.
Their paths and encoding are unchanged. Local discovery validates repository
metadata separately from draft contents and retains source access for repairing
invalid drafts; incomplete services do not make the entire Local repository
unavailable. Read-only repositories still require valid service file structure.
Portable repository, manifest, installer, and skill-package contracts are owned
by `packages/protocol`; `packages/services` supplies filesystem skill readers.
The iOS supported-version list is generated from the shared repository contract. Native codecs, persisted paths, and representations
are unchanged by this ownership extraction; legacy handling stays behind
`StorageMigrator`.

Repositories declare `version` 3 in `repository.json`; version 2 is normalized
by the repository-skill migration before loading. Version 1 is retired for external
repositories. `service.json` carries no version. `actions.js`
calls `window.ox.install(installer)`, and the installer receives only `action` for
web and `action` plus `request` for API. On preparation, `StorageMigrator`
rewrites a Local `repository.json` at version 1 to version 2 without changing
retained Git metadata. The app does not rewrite Action implementation source: sources that pass a
version to `install` or use the retired `retryFetch`, `log`, `lib`, or fetch
capture fail validation with an actionable error and must be repaired by hand.
Builds older than iOS 1.0.7 reject version 2 Local repositories and
single-argument installers instead of interpreting them.
`ox.service.validate` checks a complete Local draft, including file structure,
manifest, action registration, and service size limits. Root skill packages are
validated separately with the shared package loader. The same
validator runs before loading Local source for a caller. Failed
validation leaves the draft untouched and cannot replace a conversation's running
attachment. `ox.service.attach` validates and replaces that conversation's attachment when
the draft is ready to test. No validation result is persisted.

Development and installed sources are read-only `HEAD` snapshots without Git metadata.
Local source and all service snapshots are excluded from device backup.
Exporting Local creates a transient Files-shareable folder copy containing all
current source, repository-root skills, incomplete drafts, and any retained legacy
`.git` directory. Retained Git history does not track edits made by this build. The
copy excludes repository enablement, conflict choices, credentials, and installed
repository snapshots. Export does not validate or modify the source repository.

Simulator builds may also load the launch-configured Ox Server `HEAD` snapshot at
`Application Support/service-repositories/development/` as a separate development
repository.

## Website state

The iOS service page pool uses one persistent app-wide `WKWebsiteDataStore`.
WebKit's same-origin policy separates origin storage, while cookies follow
normal browser domain rules. Signing out enumerates WebKit records and cookies,
then removes only entries mapped to that website's Public Suffix List-aware
registrable domain. The list is shipped in `PublicSuffixList.bundle` and looked
up by [WebsitePublicSuffixList](../../../../apps/shared/Host/Services/Web/WebsitePublicSuffixList.swift)
using [the bundled rules](../../../../apps/shared/Resources/PublicSuffixList.bundle/public_suffix_list.dat).
Interactive sign-in and throwaway browsing use separate
pages with the same persistent store but separate DOM, history, and
`sessionStorage`.

Website conversations use owned pages separate from the ordinary Action pool.
`WebConversation` routes the shared `conversation` Action for conversation-tool,
Canvas, and direct Client owners. Websites cannot run the Ox agent's model loop.
Owners share the persistent website
account store, but not pages, DOM, history, session storage, or conversation IDs.
The native conversation/submission registry is process-local and is never
checkpointed. Opaque handles appearing in archived tool results cannot restore
work after page/process loss. Source replacement, scope cleanup, interruption,
and memory pressure release pages; idle nonbusy sessions expire when pruned
(after ten minutes; active submissions have an absolute one-hour lifetime,
without claiming remote cancellation). Retention is bounded to 12 open/opening pages and, for the
shared contract, 32 submissions per page. Existing installed/Local manifests,
JavaScript, saved selections, and approvals are not rewritten by this additive
contract. No new persisted format or migration is introduced.

Simulator bootstrap can make an explicit one-way copy of cookies and local
storage between two running numbered simulators. It serializes the source's
global website data store with WebKit, holds the opaque credential-bearing blob
only in host process memory, replaces those target data types, then discards
the blob. Bootstrap profiles persist only whether website data should be copied. Device templates can additionally reference an explicit private website-session snapshot captured by `sim:website-export`; those credential-bearing files stay outside Git with mode 0600. Restore uses the same cookie/local-storage owner and requires independent authentication verification. The simulator-to-simulator transfer does not
merge state, continuously synchronize devices, enter logs or arguments, or
become part of Ox and test artifacts.

WebKit 26.0 and 26.2 reject IndexedDB as unsupported by this serialization API;
bootstrap therefore leaves target IndexedDB data unchanged.

## Provider configuration and credentials

New-conversation provider/model defaults, provider additions and overrides, region,
and language are stored in UserDefaults. Each conversation persists its own
provider/model selection. Conversation saves write the existing `nativeReasoningEffort`
metadata field for non-Pi effort values; null defers to Pi thinking. They explicitly
clear Pi thinking when the selected model has no compatible effort; a switch must not retain
its predecessor's reasoning choice. `llm.providerCatalog` contains a format-2 JSON envelope
with saved provider definitions and their declared models. Bundled definitions
remain the base; a saved definition replaces the entire bundled definition with
the same ID or adds a new provider. Deleting an override restores its bundled
default; deleting an added definition removes it entirely. A saved definition
with no models disables that provider for model selection. An empty saved catalog
uses bundled defaults. `ox.provider.default` returns a fresh copy of
bundled definitions without changing storage. Provider JSON excludes credentials.
Providers use API transports; website services never enter the provider catalog.
Existing website defaults and conversation selections remain stored as unavailable choices
until the user explicitly selects a replacement. They cannot silently fall back to
another provider. History, credentials, website state, service sources, and approvals
are retained; no new persisted format or Profile milestone is introduced. Catalog format compatibility, conversion from the earlier format-1 overlay
(deleted built-ins become saved replacements with no models), removal of legacy
saved website provider definitions,
legacy `llm.customProviders`, and regional selection transforms belong solely
to `StorageMigrator`. Unknown catalog formats fail closed without overwriting
their bytes.

Reusable credentials use generic-password Keychain accounts `secret:<key>` under
the bundle-derived `<application bundle identifier>.llm` service. Each item is a
validated flat UTF-8 JSON object of string fields (16 KiB maximum). New items use After First Unlock
This Device Only accessibility. `secret.index` in app UserDefaults is a version-1
JSON `SecretIndex` with entries (key, display name, origin, use policy) and
bindings (consumer kind and ID, key, destination, configuration fingerprint,
required fields). Values are absent from the index. A missing Keychain item
keeps its metadata but cannot authenticate. Unknown index versions fail closed.
`StorageMigrator` converts predecessor `vault.index` metadata and `vault:<key>`
Keychain accounts into `secret.index` and `secret:<key>` before credentials are
read. It renames each binding's `vaultKey` field to `secretKey`, verifies copied
values, and removes old records only after the new records are durable. The
compatibility gate copies and verifies old `api:<credential ID>` provider
keys before deleting their source items. Standard provider credential IDs include
the provider ID and a hash of endpoint and auth; registered custom adapters
retain their credential identity and check the current configuration at use.
Older provider-ID accounts can coexist with their destination-scoped copies;
the compatibility gate removes each old account only when its value exactly
matches a bound Secret entry, retaining any unmatched account for recovery.
Provider deauthentication removes its binding and deletes an unshared entry
generated for that provider. Named entries remain until removed in Secrets.

Flow-managed OAuth bundles remain separate Keychain items with After First Unlock
accessibility. Their account families are `oauth:model-provider:<credential ID>`,
`oauth:mcp-service:<endpoint hash>`, and `oauth:api-service:<identity hash>`.
`StorageMigrator` copies, verifies, and removes predecessor `oauth:<credential ID>`,
`oauth:mcp:<endpoint hash>`, and OAuth `service:api:<identity hash>` items. OAuth
envelopes are never exposed as Secret entries.

Repository proposals store a validated classic GitHub personal access token in
`secret:ox.repository.github` as `{"token":"…"}` with a publication-only binding
to OpenOx's GitHub API destination. `StorageMigrator` moves the predecessor
`pat:service-repository:github` item after verifying the new entry. The account
login is fetched from GitHub, not persisted. Invalid or revoked saved tokens and tokens missing
public-repository scope are removed before prompting for replacement. Transient
network failures preserve the token. Tokens never enter conversation transcripts or
model inputs. Users can revoke the token in GitHub Settings.

The application compatibility gate deletes the former
`oauth:service-repository:github` item before consumers start. OAuth tokens are
never copied to the PAT account, and provider credentials remain separate.
Deletion is retryable; the PAT flow never reads the legacy item, even if cleanup
is deferred by Keychain availability. Local deletion does not revoke GitHub grants.

Built-in provider keys in `apps/shared/Host/ModelProviders/Secrets.swift` are compile-time binary
contents rather than device storage.

## Logs

`Library/Application Support/logs.jsonl` is the durable structured log. Each
line contains timestamp, level, category, source location, and message. Writes
flush periodically, on a pending threshold, and during lifecycle transitions.
When the file exceeds 10 MiB, compaction retains roughly the newest 5 MiB of
complete lines. There is no age-based expiry.

This file is the sole app diagnostic store. The CLI and other Clients read a
filtered, cursor-paginated history through `logs.list` (up to 2,000 records per
page); the approval-gated `ox.app.logs` function
filters the retained file, including previous app runs. Reads flush pending writes
and run on the log file's serial utility queue. No Logs row or viewer appears in
Settings, and no separate in-memory history is retained. The existing JSONL path
and record format are unchanged, so previously written logs remain readable
without a migration. RPC cursors carry only transient read positions and filter
bindings; no pagination index or cursor state is persisted. They survive appends
and restarts, but fail explicitly after compaction or file replacement.

Logs stay outside Profiles, Files, iCloud, and backup. Logs may contain user data
needed for diagnosis but never credentials or reusable secrets.

## Retention summary

| State | Location | Backup or sync | Removal |
|---|---|---|---|
| Local Profile content | Documents/Profiles/<name> | No device backup | Delete or move the Profile |
| Profile state | <selected folder>/.ox (identity manifest at root) | Travels with the folder; no cross-device editing coordination | Delete the Profile; closing an external Profile preserves it |
| Profile migration recovery | Application Support/StorageMigration | Private retained source/stage material | Explicit recovery/diagnostic cleanup |
| iCloud Profile content | iCloud Documents | iCloud Drive | Delete or move the Profile |
| Temporary conversation | Memory and isolated filesystem cache | None; cache is purgeable | Leave conversation; private cache by eviction, app deletion, or explicit QA cleanup after close |
| Conversation-owned files | Profile directory | Profile policy | Delete owner conversation or delete file |
| Shared files | Profile directory | Profile policy | Delete file, folder, or Profile |
| Active provider catalog | UserDefaults | Device backup policy | Delete provider or app |
| Secret values | Keychain | This device only | Sign out generated entry or delete any entry |
| Secret metadata and bindings | UserDefaults | Device backup policy | Sign out or delete entry |
| Managed provider OAuth | Keychain | System policy | Sign out |
| Service website state | Domain website store | Local persistent state | Sign out service family |
| Remote MCP endpoints and transports | Documents/Repositories/Local | Device backup policy | Disconnect the MCP server |
| Scheduled skill definitions | Application Support | Device backup policy | Delete the schedule or app |
| Remote MCP OAuth registration and tokens | Keychain | System policy | Disconnect the MCP server |
| Service repository configuration | Application Support | Device backup policy | Remove repository or reset choices |
| Local repository and service snapshots | Application Support | Excluded from backup | Remove repository or replace snapshot |
| Service-search vectors | Caches | Purgeable local cache | System eviction or MonoRepository rebuild |
| Pi Durable temporary-conversation caches | Caches (explicit launch opt-in) | Purgeable; no backup/sync/export | System eviction, app deletion, or explicit QA cleanup after close |
| Pi Durable upstream storage diagnostics | Caches (DEBUG Simulator only) | Purgeable; no backup/sync/export | Removed after each request; crash remnants by system eviction or QA cleanup |
| Folder grants | Application Support | Excluded from backup | Remove or replace grant |
| App logs | Application Support | Excluded from backup | Retention compaction |

## API service credentials

API service manifests and handlers use the existing repository package layout at
`api/<service-id>/service.json` and `actions.js`, with `api:<service-id>` entries
in repository.json. Existing web, iOS, and MCP representations are unchanged.
Older readers reject the unsupported API package identity rather than interpreting
it as a website service. No legacy data transform is needed for this additive kind.

The API-service identity hash derives from repository ID and service domain.
Static API keys, bearer tokens, and Basic username/password pairs are JSON Secret
entries with a binding to that identity, canonical auth configuration, and API
base URL. `StorageMigrator` converts matching version-1 predecessor envelopes
from `service:api:<identity hash>` and removes each source after verifying its
new credential and binding. OAuth version-1 envelopes retain their format under
`oauth:api-service:<identity hash>`. The binding hash covers auth configuration,
API base URL, repository ID, and service domain; a mismatch requires setup.
Sign out unbinds static credentials or removes the managed OAuth envelope.
Replacing a static credential writes a dedicated Secret entry for that service.
Auth status is observed at runtime rather than persisted.

## External Pi session server

[pi-mcp](https://github.com/ziyzhu/pi-mcp) owns the former `ox serve` storage;
it is not an iOS Profile. Existing `~/.openox/serve` stores remain unchanged and
can be opened with `--data-dir ~/.openox/serve` after stopping the old server.
Version-1 metadata, Pi JSONL files, and lock layout are unchanged; no app migration
or automatic relocation occurs. New stores default to `~/.pi-mcp`. See pi-mcp's
README for storage, locking, and retention details.

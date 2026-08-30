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
│   │   ├── autoApproveActions               standing per-action approvals
│   │   ├── autoApproveAll                   global Always approve setting, off by default
│   │   ├── remoteMCPServers                  directly connected MCP URLs and transports
│   │   ├── api.url                          Ox service API override
│   │   ├── llm.selectedModels               client → new-chat model default
│   │   ├── llm.selectedReasoningEfforts      client/model → new-chat thinking level
│   │   ├── llm.defaultClient                new-chat provider default
│   │   ├── llm.customProviders              custom provider names and endpoints
│   │   ├── app.region                       last detected network region
│   │   ├── app.language                     UI and agent language override
│   │   ├── speech.voice.identifier          read-aloud voice preference
│   │   ├── storage.activeProfile            active profile UUID
│   │   └── chatgpt.installationId           per-install Codex client ID
│   ├── Application Support/
│   │   ├── service-repositories.json        enabled repositories and conflict resolutions
│   │   ├── service-repositories/local/      editable local git working tree
│   │   ├── service-repositories/development/ simulator development HEAD snapshot
│   │   ├── service-repositories/<uuid>/     installed public HEAD snapshots
│   │   ├── external-profiles.json           external profile folder bookmarks
│   │   ├── device-folder-grants.json         security-scoped folder bookmarks
│   │   ├── scheduled-skills.json             device-owned scheduled skill snapshots
│   │   └── logs.jsonl                       capped structured diagnostics
│   ├── Caches/
│   │   └── ServiceSearchVectors.plist       purgeable service-search embeddings
│   └── ...                                  system-managed framework state
├── Documents/                               local Profile catalog
│   └── <ProfileName>/
│       ├── profile.json
│       ├── chats/<uuid>/
│       │   ├── chat.json
│       │   ├── turns.jsonl
│       │   └── context.json                 compacted chats only
│       ├── artifacts/
│       │   ├── .saved.json                  saved artifact basenames
│       │   └── <filename>
│       ├── skills/<name>/SKILL.md
│       ├── SOUL.md
│       └── MEMORY.md
├── Keychain                                 provider and service credentials
└── WKWebsiteDataStore(forIdentifier:)       per-site website state

<configured iCloud container>/
└── Documents/<ProfileName>/              same Profile layout

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
website-data namespace directly from that bundle identifier. Agent skill and chat
packages use canonical OpenOx type identifiers; the app continues importing the
legacy bundle-derived identifiers.

Primary owners:

- UserDefaults onboarding state — owner: App.swift
- UserDefaults service state — owner: Services/ServiceManager.swift
- UserDefaults model state — owner: LLMConfiguration/LLMRegistry.swift
- Keychain credentials — owner: Host/Profile/Credentials.swift
- UserDefaults read-aloud voice — owner: Models/SpeechVoiceSettings.swift
- App-group theme — current value owners: Theme.swift and ShareExtension; legacy migration owner: Host/Profile/StorageMigration.swift
- Fixed app-storage paths and backup policy — owner: Host/Profile/AppStoragePaths.swift
- Active and saved profiles — owners: Host/Profile/StorageRoot.swift and Host/Profile/ProfileStore.swift
- Profile content — owner: Host/Profile/ProfileRepository.swift
- All compatibility detection, orchestration, and migration steps — owner: Host/Profile/StorageMigration.swift
- Artifact metadata — owner: Host/Profile/Artifact.swift
- Folder bookmarks — owner: Services/Native/DeviceFolderStore.swift
- Service repositories — owner: Services/Repository/ServiceRepository.swift
- Service-search vector cache — owner: Services/Repository/ServiceSearchIndex.swift
- App log file — owner: Debug/LogFile.swift
- Shared note inbox — owner: Host/Profile/SharedNoteInbox.swift and ShareExtension
- Scheduled skill definitions and run state — owners: Host/Profile/ScheduledSkills.swift and Host/Chats/ScheduledSkillScheduler.swift
- Developer bootstrap credentials — owner: tooling/sim-bootstrap.ts

## Compatibility gate

`StorageMigrator` is the single compatibility entry point. App-wide structural
migrations run before the Host and its storage consumers are constructed. Host
preparation then validates application storage, migrates the selected Profile,
and prepares the Local service repository before chats, service discovery, or
search indexing load persisted state. Selecting or opening another Profile also
migrates it before publishing its `ProfileScope`.

The same `StorageMigrator` owns ordered Profile milestones and the scoped
transforms used by the gate. All of that code stays in the single
`Host/Profile/StorageMigration.swift` file. Service-repository repair remains
structurally detected because the old Local layouts predate a shared application
schema marker. Unknown Profile versions and unsuccessful migrations fail closed
at the loading screen rather than allowing consumers to interpret incompatible
data.

## Shared preferences

The app-group `app.theme` value is the single theme source shared by the app and
ShareExtension. On first launch after upgrading, the app copies a legacy standard
UserDefaults value into the app group and removes the legacy value.

Application migration removes standing approvals for retired action identifiers.
It does not transfer approval to replacement actions, so a replacement that can
expose user data requires fresh consent.

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
Only security-scoped bookmarks for folders opened from outside Ox's app
directories are persisted in `external-profiles.json`. When no external profiles
are registered, that file does not exist.

Profiles can use three storage locations:

- Local profiles are immediate children of the app's Documents directory. They are
  visible in Files and excluded from iCloud device backup.
- iCloud profiles are immediate children of the app's public iCloud Documents
  directory. They have the same internal layout and may be evicted or changed by
  another device.
- External profiles remain in a user-selected Files folder outside Ox's local and
  iCloud Documents directories. Ox holds the folder's security scope while it
  is registered and reads and writes the vault in place. Closing an external
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
to soul, memory, skills, visible artifacts, and chat summaries. Hydrated chats
remain authoritative in memory and are not blindly replaced.

Multi-writer conflict preservation for a chat simultaneously edited on more than
one device remains undefined. Current ordering guarantees apply to one running
app's writes.

## Chats

Each persisted chat owns one directory:

- `chat.json` contains `ChatMeta`: schema version, identity, dates, title,
  favorite state, provider/model/thinking-level choice, MonoRepository hash, attached
  services, sidebar preview, and whether the latest completed response is
  unread. Chats created by a scheduled skill execution also retain that
  schedule's identifier so clients can group them separately from recent chats.
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

`ChatManager` retains the selected chat and up to four inactive chats in memory.
Each chat has one save pump: one immutable request may be in flight, and newer
complete state replaces one pending-latest slot. Exact save IDs prevent an old
completion from acknowledging newer state.

Hydrating interrupted work converts running turns, executions, and invocations,
plus pending prompts, to terminal cancelled or failed states and persists the
repair. Backgrounding flushes all chats while active workers continue under
their execution leases. Submissions not yet posted to the transcript are not
durable.

A temporary chat has no directory, summary, persistence callback, or
notification preview. It is discarded when left or when the process ends and
cannot mutate Profile-owned content.

Chat sharing creates a transient `.chat` ZIP package whose `chat.json` stores
the package and transcript schema versions, source metadata, content counts,
service-domain disclosure, and SHA-256 inventory. `turns.jsonl` retains the
semantic transcript; `context.json` is included only for compacted chats so
continuation state is not lost. Legacy packages with redundant uncompacted
context remain readable and normalize to transcript-only storage on import. The
package also contains transcript- or
checkpoint-referenced artifacts and supported sibling media dependencies.
Import validates ZIP paths, compression, CRCs, declared hashes, transcript
state, checkpoint digests, compaction completeness, and artifact references
before presentation. Confirmation stages a new chat identity and collision-safe
artifact filenames, rewrites both transcript and checkpoint references, rebuilds
checkpoint digests, and installs the files as one repository transaction. It
does not restore provider selection, service attachments, pending work, or any
state outside the package.

Legacy chat and artifact layouts migrate through retry-safe Profile schema
milestones. A milestone is stamped only after every required operation succeeds;
an interrupted migration preserves a recoverable source or equivalent
destination and resumes on the next activation.

## Artifacts

`artifacts/` is a flat directory of ordinary files plus a hidden `.saved.json`
index containing the basenames the user saved. The case-insensitive basename is
the stable identity; type, MIME type, size, and dates are derived from the file.
Imports sanitize names and resolve collisions with numbered suffixes. Text is
limited to 200 KB, other files to 32 MB, and imported images are bounded before
storage. Artifact rename and deletion keep the saved index aligned with the
user-visible file operation.

Chats persist live filename references. Editing changes what an old chat opens.
Deleting or externally renaming a file leaves a missing reference. Profile-owned
renames rewrite persisted chat references and canonicalize later saves from
already-hydrated chats.

Remote MCP image and embedded-resource tool content is imported into the active
Profile before it is presented in chat. The MCP server retains its source copy;
Ox stores a collision-safe artifact file and the chat stores the same live
filename reference used by locally created artifacts. Local, iCloud, and
external Profile locations therefore keep their existing artifact persistence
and synchronization behavior.

Browser full-page PDF exports remain transient unless the action supplies an
artifact filename. Named exports use the same validation, collision-safe import
path, Profile ownership, live chat reference, and synchronization behavior as
other PDF artifact imports.

The agent sees a virtual filesystem containing `MEMORY.md`, `SOUL.md`,
`artifacts/<filename>`, persisted chat history, and source-aware skill and service
mounts:

```text
skills/
├── <skill-name>/SKILL.md                        read-write, active Profile
├── system:<skill-name>/SKILL.md                 read-only, app-owned
└── service:<domain>:<skill-name>/SKILL.md       read-only, attached service

services/
└── <kind>/<id>/
    ├── service.json                            read-only except Local
    └── ...                                      visible and editable only for Local

chats/
└── <chat-uuid>/
    ├── chat.json                                read-only, stored metadata
    └── turns.jsonl                              read-only, stored transcript
```

The mount resolves permissions from each entry's source. A prefix is part of
the virtual address, not an authority claim supplied by file contents. Only
currently attached service skills are visible. Every selected service exposes
its manifest for discovery. Bundled, Remote, and Development source files remain
hidden and read-only; Local exposes its additional source files at the same
`services/<kind>/<id>/` path. Repository host paths, markers,
`chats/<chat-uuid>/context.json`, and unrelated vault contents are not
addressable. The chat mount returns the canonical files already persisted by
`ProfileRepository`; it does not introduce a second transcript representation.
Unscoped root grep excludes chat files, while an explicit `chats` path searches
JSONL records with a separate bounded byte budget and match-centered excerpts.
Reads and searches are bounded; writes are atomic; writes and edits to the same
file are serialized; edits require exact non-overlapping matches.

User-selected Files folders appear separately as `files/<grant-id>/...` after
the Files device service is attached. Security-scoped bookmarks live in
`Application Support/device-folder-grants.json`, outside every Profile and outside
backup. Each operation rejects traversal and symbolic links. Writes, edits, and
deletes require their device-service approval. Profile-owned writes and edits do
not require approval; artifact import, rename, and delete do.

HTML artifacts remain ordinary UTF-8 files. Presentation creates a fresh
non-persistent WebKit store and reads the current artifact plus bounded sibling
media through `ox-artifact:` URLs. Maps use `<ox-map>` and `<ox-marker>`. The
renderer itself does not add durable website state. Canvas service calls use the
Host's existing service accounts. Canvas owns no chat, attachment list, or permission
store. Service-produced files live in a presentation-owned temporary directory,
are bounded by the Host, and are deleted on close.

Shoveler cards persist an optional artifact filename in the chat transcript.
Opening a card resolves that reference in the active Profile and uses the same
native artifact preview as other chat artifact references. Chat package export
includes artifacts referenced only by Shoveler cards.

Video widgets persist a public HTTPS source or an artifact filename in the chat
transcript. Artifact-backed videos participate in rename, package export, and
collision rewriting like other artifact references.

The Share extension converts user-selected shared text into a Markdown file in
the app-group staging directory, then atomically moves its directory to Pending.
The app reads only complete Pending directories on activation, imports each file
through the normal collision-safe artifact path, and removes a directory only
after its artifact succeeds. Failed copies remain pending for a later retry.

## Soul, memory, and skills

`SOUL.md` and `MEMORY.md` are plain UTF-8 text. They are seeded when absent,
cached for presentation, and written atomically. Both reload after Profile switches;
only `SOUL.md` reloads after relevant external changes. Each chat snapshots the
loaded memory into its system prompt so later memory changes do not invalidate the
chat's prompt cache. An existing unreadable or cloud-evicted file is not overwritten.

Each user skill is one `<name>` directory containing `SKILL.md`, where `<name>`
is lowercase kebab-case. The `system:` and `service:` namespaces are reserved
for virtual read-only entries.
Frontmatter stores its matching name, description, and optional service list;
the body stores instructions. Creation, update, and deletion are scoped to the
active Profile and refresh the shared skill catalog. Saving a skill does not select
or execute it.

Skill sharing creates a transient `.skill` ZIP archive containing the skill
directory and `SKILL.md`. Incoming archives remain external until the user
confirms import; Ox then validates and writes the skill through the same
active Profile repository path. The archive itself is not retained.

`Application Support/scheduled-skills.json` is a versioned device-owned document
containing at most 100 scheduled invocations. Each record binds to one Profile UUID
and stores a frozen user-skill snapshot, optional argument, one-time/daily/weekly
recurrence, time zone, next occurrence, enabled state, and bounded last-run outcome
with its result chat UUID. The file is validated by `StorageMigrator` before the
scheduler reads it; unknown versions and malformed or duplicate records fail closed.
It follows Application Support's normal device-backup policy and never syncs through
the Profile, preventing one iCloud Profile from executing on several devices.

Only schedules bound to the active Profile execute. A due record for another
Profile advances once as a failed occurrence and notifies when authorized. Each run
uses the saved skill snapshot, creates an unselected persisted chat in the bound
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

The editable Local repository always exists at `service-repositories/local/` and
cannot be disabled or removed. It receives preinitialized metadata for an empty
repository only when `.git` is absent; existing metadata, commits, index state, and
working-tree changes are never replaced when valid. Legacy metadata with an unborn
`master` reference is repaired by restoring `HEAD` to an existing `main` tip or,
when it has no references, replacing only its metadata with the empty seed.
Local source files remain untouched as working-tree changes against that seed.
Legacy Local source without Git metadata follows the same working-tree path. The
repository never introduces another virtual directory: its selected services
resolve directly into `services/<kind>/<id>/`. Local file writes are atomic and
enforce write permissions, path containment, symbolic-link rejection, and the
general file size limit without validating service contents. Working-tree drafts
may contain incomplete, missing, or inconsistent service files across app restarts.
Their paths and encoding are unchanged. Local discovery validates repository
metadata separately from draft contents and retains source access for repairing
invalid drafts; incomplete services do not make the entire Local repository
unavailable. Read-only repositories still require valid service file structure.
`ox.service.validate` checks a complete Local draft, including file structure,
manifest, action registration, declared skills, and service size limits. The same
validator runs before Save and before loading Local source for a caller. Failed
validation leaves the draft untouched and cannot replace a chat's running
attachment. `ox.service.attach` validates and replaces that chat's attachment when
the draft is ready to test. No validation result is persisted.

Only Local exposes Git status, history, diff, checkout, commit, revert, and
restore operations. Checkout detaches its working view without moving `main`;
historical views are read-only until returning to the latest tip. Development
and installed sources are read-only `HEAD` snapshots without Git metadata.
Local Git objects and all service snapshots are excluded from device backup.

Simulator builds may also load the launch-configured Ox Server `HEAD` snapshot at
`Application Support/service-repositories/development/` as a separate development
repository.

## Website state

The iOS service page pool uses one persistent app-wide `WKWebsiteDataStore`.
WebKit's same-origin policy separates origin storage, while cookies follow
normal browser domain rules. Signing out enumerates WebKit records and cookies,
then removes only entries mapped to that website's Public Suffix List-aware
registrable domain. Interactive sign-in and throwaway browsing use separate
pages with the same persistent store but separate DOM, history, and
`sessionStorage`.

Simulator bootstrap can make an explicit one-way copy of cookies and local
storage between two running numbered simulators. It serializes the source's
global website data store with WebKit, holds the opaque credential-bearing blob
only in host process memory, replaces those target data types, then discards
the blob. Profiles persist only whether website data should be copied. The transfer does not
merge state, continuously synchronize devices, enter logs or arguments, or
become part of Ox and test artifacts.

WebKit 26.0 and 26.2 reject IndexedDB as unsupported by this serialization API;
bootstrap therefore leaves target IndexedDB data unchanged.

## Provider configuration and credentials

New-chat provider/model defaults, custom provider names and endpoints, region,
and language are stored in UserDefaults. Each chat persists its own
provider/model selection. Custom-provider models and capabilities are discovered
at runtime and are not persisted. Custom-provider JSON excludes credentials.

Provider API keys and subscription token bundles are generic-password Keychain
items under the bundle-derived `<application bundle identifier>.llm` service. They use After First Unlock accessibility
so user-invoked background Siri and CarPlay requests can run after the device's
first unlock following a restart. Custom endpoint bearer tokens attach only to
their normalized configured endpoint. Providers with different global and China
accounts store the global credential under the provider ID and the China
credential under `<provider-id>:china`. Signing out removes the corresponding
regional Keychain item.

Built-in provider keys in `apps/ios/Ox/Host/ModelProviders/Secrets.swift` are compile-time binary
contents rather than device storage.

## Logs

`Library/Application Support/logs.jsonl` is the durable structured log. Each
line contains timestamp, level, category, source location, and message. Writes
flush periodically, on a pending threshold, and during lifecycle transitions.
The file is capped at 10 MB by retaining the newest portion.

Logs stay outside Profiles, Files, iCloud, and backup. Export shares the file.
Clearing the in-memory log view does not erase its durable history. Logs may
contain user data needed for diagnosis but never credentials or reusable
secrets.

## Retention summary

| State | Location | Backup or sync | Removal |
|---|---|---|---|
| Local Profile content | App Documents | No device backup | Delete or move the Profile |
| iCloud Profile content | iCloud Documents | iCloud Drive | Delete or move the Profile |
| Temporary chat | Memory | None | Leave chat or terminate process |
| Provider credentials | Keychain | System policy | Sign out or clear credential |
| Service website state | Domain website store | Local persistent state | Sign out service family |
| Remote MCP endpoints and transports | UserDefaults | Device backup policy | Disconnect the MCP server |
| Scheduled skill definitions | Application Support | Device backup policy | Delete the schedule or app |
| Remote MCP OAuth registration and tokens | Keychain | System policy | Disconnect the MCP server |
| Service repository configuration | Application Support | Device backup policy | Remove repository or reset choices |
| Local repository and service snapshots | Application Support | Excluded from backup | Remove repository or replace snapshot |
| Service-search vectors | Caches | Purgeable local cache | System eviction or MonoRepository rebuild |
| Folder grants | Application Support | Excluded from backup | Remove or replace grant |
| App logs | Application Support | Excluded from backup | Retention compaction |

# File-based app configuration

Status: implemented. Both native targets, portable CI, native contracts, and targeted migration/filesystem E2E checks pass; broader coverage limits remain below.

Goal: make files authoritative for app-owned configuration, expose safe configuration and live information through the existing agent filesystem, and remove the agent-facing `ox.app.*` namespace. Use `ox.fs.write` and `ox.fs.edit` for permitted configuration changes without weakening validation or authorization.

## Direction

- Replace current app-owned UserDefaults settings and persistent state with explicitly versioned files. System/framework preferences are outside this scope.
- Keep credentials and OAuth tokens in Keychain, website state in WebKit, caches in Caches, and history/execution state in the Profile database.
- Keep app/device configuration outside portable Profiles and Profile exports. Do not change Profile database formats merely to reorganize app settings.
- Expose selected files through reserved virtual mounts, not raw Application Support paths. No physical paths, bookmarks, credentials, or installation identity in agent-visible views.
- Use existing configuration owners, filesystem routing, and approval machinery. Do not add a universal configuration framework, replacement settings-tool namespace, or new PolicyEngine for this work.
- Files are the single authority. No permanent UserDefaults/file dual writes or persisted copies of generated status.
- Policy and security controls remain agent-read-only. An Allow policy cannot grant write access to a protected file.

## Predecessor storage and owners

| State | Current location | Owner |
| --- | --- | --- |
| Language | UserDefaults `app.language` | `AppLocale` |
| Region | UserDefaults `app.region` | `AppRegion` |
| Host connection permission | UserDefaults `host.allowConnections` | `HostAccess` |
| Onboarding and starter count | UserDefaults | `App`, `ConversationComposer` |
| Active Profile | UserDefaults `storage.activeProfile` | `StorageRoot` |
| Saved services and display names | UserDefaults | `ServiceManager` |
| Action policy | UserDefaults JSON `actionApprovalPolicies` | `ServiceManager`, `ActionPolicyConfiguration` |
| Secret metadata/bindings | UserDefaults JSON `secret.index` | `Secret` |
| ChatGPT installation identity | UserDefaults `chatgpt.agentHostID` | `ChatGPTSubscriptionAccount` |
| Provider definitions/default | Application Support `providers.json` | `ProviderCatalog`, `ProviderRegistry` |
| Repository configuration | Application Support JSON files | Repository owners |
| Profile bookmarks | Application Support `external-profiles.json` | `ProfileStore` |
| Native folder grants | Application Support `device-folder-grants.json` | `DeviceFolderStore` |
| Profile history/settings/schedules | Profile `.ox/state.sqlite` | Pi Durable and Profile owners |
| Memory, skills, working files | Portable Profile directory | Profile filesystem |
| Credentials and OAuth | Keychain | Credential owners |

The canonical storage inventory also contains retained predecessor formats. Confirm current consumers before migrating any legacy key; do not turn ignored preferences into active settings. Preserve unrelated uncommitted service/authentication changes.

## Physical layout

Implemented layout under `Library/Application Support`:

```text
Configuration/
  settings.json                 User-facing preferences such as language
  policy.json                   Global/source/action approval overrides
  services.json                 Saved domains and display names
  providers.json                Existing provider definitions and default model
  service-repositories.json     Existing repository configuration
  mounted-repositories.json     Existing mounted-repository bindings
  external-profiles.json        Existing selected Profile bookmarks
  device-folder-grants.json     Existing native folder grants
  secrets.json                  Secret metadata/bindings, never secret values
  host.json                     Host access preference; protected from agent writes
state.json                      Active Profile, onboarding, starter count,
                                installation identity, last detected region
logs.jsonl                      Existing retained diagnostics
```

- Inventory whether region has an independently writable preference versus detected state before finalizing its fields. Preserve existing behavior rather than introducing a new region setting.
- Preserve current backup eligibility for each moved file. Configuration is not automatically portable; bookmarks and installation identity retain their device-local semantics.
- Keep existing staging, migration recovery material, and public repositories in their current locations.
- Move existing JSON configuration into `Configuration/` only after the initial preference migration works; avoid coupling every owner to the first implementation step.
- Keep each domain's existing schema where possible; add explicit versions for new envelopes. Use stable, pretty-printed, sorted JSON suitable for exact edits.

## Agent filesystem

Agent-visible layout:

```text
app/
  settings.json                 Writable supported preferences
  policy.json                   Read-only approval overrides
  providers.json                Managed provider/default-model edits
  services.json                 Managed supported service preferences
  status.json                   Generated app/runtime information, read-only
  actions/<encoded-action>.json Exact-action default/effective policy and origin
  logs.jsonl                    Protected redacted diagnostic view
```

- Use one reserved `app/` root for accepted configuration and generated live views. Individual files declare their write permissions and whether they are stored configuration or generated state; live views never become persisted duplicate status.
- `status.json` combines app name/version/build, effective language/region, Host access preference, notification authorization, safe Profile inventory with active marker, effective default model/authentication readiness, and safe repository status. Keep these as named sections, generated on read from their existing owners. Do not persist a status snapshot or expose private identifiers, bookmarks, native paths, or credentials.
- Keep configured values in editable files and effective values in status explicitly distinguished. Bound generated inventories and disclose truncation or unavailable sections; do not silently omit failures or perform authentication, network discovery, or resource mutations while reading status.
- Keep providers and services separate because their inventories and validation grow independently; keep policy separate because it is protected. Generate exact-action policy views on demand, and keep diagnostics behind their own approval boundary. Do not recreate one file per retired getter.
- Safe files may directly represent stored configuration. Filtered views must state their scope; never present a filtered document as a writable full-file replacement.
- Profile inventory preserves the current API's privacy boundary: names, storage types, and active status, not identifiers/bookmarks/native paths.
- Define a canonical, reversible action-ID encoding before implementing exact-action paths. Do not derive arbitrary filesystem paths from action IDs or enumerate all actions on startup.
- Expose configured and effective values distinctly: system language selection versus resolved locale; optional model selection versus effective fallback; policy overrides versus resolved policy.
- Support list/read/glob/grep with existing bounds and truncation semantics. Evaluate access for every selected file, including recursive searches, attachment reads, and copies; no alternative operation may bypass a protected read.
- The reserved root cannot be shadowed by Profile files. Detect preexisting `app/` collisions and preserve existing bytes; define access to displaced user files before shipping, never silently hide or overwrite them.
- Review temporary-conversation behavior explicitly. Preserve existing restrictions; exposing an app-global mount must not accidentally enable mutations previously prohibited in temporary conversations.

## Managed writes

```text
ox.fs.write/edit
  -> normalize and route reserved path
  -> check path/operation access
  -> build proposed document against the current revision
  -> validate the document and identify semantic changes
  -> evaluate filesystem and affected domain Action policies
  -> obtain required approvals
  -> revalidate revision and dependent configuration
  -> atomically persist through the existing owner
  -> publish observable state and return accepted result
```

- Use full-document validation for write and edit, including unknown fields, schema versions, supported values, size bounds, and protected fields. Reject invalid changes without changing the previous file.
- Preserve existing default-model normalization, exact picker IDs, authentication readiness requirements, provider validation, and explicit-user-request guidance. No silent model/provider substitution.
- A generic filesystem Allow must not bypass a domain Block or required approval. Preserve current domain Action IDs for policy evaluation even after their public tool functions disappear.
- Multi-field edits collect all necessary approvals before publication. Reject unsupported multi-domain effects rather than partially applying a document.
- Bind approval to the validated revision/change; if either changes while waiting, reject the stale operation rather than applying a different mutation under old approval.
- Serialize owner writes. Reject stale edits and require a current read/revision for full replacement; define the smallest compatible extension to `ox.fs.write` if the existing contract cannot express that precondition.
- Publish in-memory state only after durable publication. Report persistence errors rather than success; never rely on a didSet that silently drops write failures.
- Reject rm/mkdir/move/rename and copy destinations under managed roots. Copying readable content out is allowed only if it satisfies the same read authorization and normal destination policy.
- Policy, Host access, secret metadata, grants, bookmarks, and internal state are not agent-writable. Keep protected settings in separate files rather than relying on a writable mixed-security document.
- Service lifecycle operations and repository connection/sync/publication remain their existing explicit actions. Do not make editing a configuration file implicitly download, delete, authenticate, or publish resources. Limit writable fields to validated preference changes with defined effects.

## Retire ox.app

| Existing function | Replacement |
| --- | --- |
| `language`, `setLanguage` | Read/edit `app/settings.json` |
| `defaultModel`, `setDefaultModel` | Read/edit `app/providers.json`; effective state from `app/status.json` |
| `actionPolicies` | Read `app/policy.json`; exact-action resolution under `app/actions/` |
| `info` | Read app identity in `app/status.json` |
| `profile`, `profiles` | Read Profile inventory in `app/status.json` |
| `notifications` | Read notification authorization in `app/status.json` |
| `logs` | Protected diagnostic filesystem view |

- Replace all registered `ox.app.*` functions, native bridge registrations, contracts, guidance, bundled references, and generated artifacts. Audit legacy constants/aliases separately from actually exposed functions.
- Preserve historical trace rendering and stored policy meanings. Retired public functions do not justify deleting the Action IDs still needed to authorize equivalent file operations.
- Do not transfer standing approvals to broader filesystem operations. A language-specific Allow cannot approve arbitrary configuration writes.
- Logs retain current app-wide disclosure, log-specific approval policy, credential redaction, output limits, and retained-file behavior. A protected file read must not implicitly authorize an entire tree search or whole-file exfiltration. Design bounded filtering/pagination with the existing fs schemas before removal; if equivalent safety cannot be expressed, report the blocker rather than expose raw logs.
- Removing tools can break saved user scripts/skills. Inventory tracked references, update bundled sources, and explicitly disclose the compatibility boundary for user-authored callers. Do not automatically rewrite user files or preserve a permanent duplicate namespace.

## Migration and recovery

- Capture an actual predecessor baseline before implementation. Inventory the first reader of each setting, including locale/onboarding before Host construction, ShareExtension, DEBUG templates, and background work.
- Run file migration before those readers. Move structural compatibility into `ApplicationStorageMigrator`, `CredentialMigrator`, and `RepositoryMigrator` under `StorageMigrator` ordering; consumers read only prepared current files.
- Compose with existing legacy policy/provider/credential transforms in a fixed order. Repository reference renames must update the new authoritative policy/service files after their migration.
- Missing legacy preferences produce current defaults on a fresh install. Malformed/future authoritative configuration is preserved and blocks affected writes; security failures never become Allow or enabled Host access.
- Publish, reopen, validate, and verify each destination before removing its source preference/file. Partial completion must resume without resetting completed files or duplicating state.
- If source and destination coexist with divergent values, preserve both and fail with actionable diagnostics; do not guess which is newer.
- Do not erase unknown legacy keys or unrelated framework preferences. Keep migration retry-safe and second-launch stable.
- Log bounded migration lifecycle, owner, version, counts, and failure categories; do not log settings payloads, secret bindings, bookmarks, or credentials.
- Update device-template capture/replay and the canonical storage map. Document known downgrade limitations; do not claim compatibility with older writers.

## Implementation status

- [x] Capture the actual predecessor build, preferences, files, and baseline reads outside Git.
- [x] Define paths, writable fields, read-revision preconditions, collision preservation, exact Action encoding, and protected logs.
- [x] Migrate preferences/state, policy, secret metadata, and service preferences; read only persisted app-domain migration inputs.
- [x] Consolidate existing JSON paths into `Configuration/` using verified, retry-safe moves; update device templates and storage inventory.
- [x] Add the managed mount through existing Swift/TypeScript filesystem routing, including temporary-conversation restrictions.
- [x] Apply edits through existing owners and semantic approvals, publishing observable state only after persistence.
- [x] Retire public `ox.app.*`, update bundled callers/contracts/guidance, and preserve internal policy IDs and historical rendering.
- [x] Verify targeted upgrade, managed-write, denial, protected-file, collision, and native contract behavior without new unit tests.

## Verification and review

- Use E2E coverage, not new unit tests. Exercise actual agent filesystem calls and native app startup/settings behavior.
- Verify language/system locale, default/automatic model selection, provider auth readiness, service preferences, Profile switches, onboarding, Host toggle, secret metadata, repository settings, and relaunch persistence.
- Verify invalid JSON/schema/value, protected-field changes, malformed/future files, stale edits, concurrent UI changes, write failure, cancellation, denial, Block, Always allow, multi-field approval, and interruption around publication.
- Verify policy writes and alternate-path writes are rejected; check dot paths, traversal, root collisions, cross-root move/copy, search, attachments, and temporary conversations.
- Verify log-specific approval/redaction across every readable operation, no private data from root-wide searches, and no credential/bookmark/path leakage in views or diagnostics.
- Run actual predecessor Before -> changed build migration, changed After -> changed build, and second-launch stability on isolated QA simulators. Preserve immutable before/after templates, snapshots, hashes, complete tree diffs, and logs outside Git. Missing predecessor evidence blocks upgrade verification.
- Consult Apple documentation for Application Support placement, atomic writes/file protection, backup behavior, Keychain, and native settings observation before native implementation.
- Run type/static/generated-artifact/protocol checks as affected. Build both iOS and macOS for shared native changes before committing; report blockers and obtain approval before any commit if either required build cannot run.
- Review LOC delta, file-tree diff, call-stack diff, cyclomatic complexity, and performance per implementation commit. Bound file reads, policy lookups, generated views, and searches; avoid startup inventory of all Profiles/actions/logs.
- Capture simulator screenshots for changed UI states, or mark visual review non-applicable if presentation is unchanged.

Implemented call-stack change:

```text
Before: ox.app getter -> native bridge -> configuration/runtime owner
After:  ox.fs.read -> reserved mount -> configuration/runtime owner

Before: ox.app setter -> semantic approval -> validated owner mutation
After:  ox.fs.write/edit -> managed mount -> revision/schema validation
        -> filesystem + semantic approval -> validated owner mutation

Before: owner -> UserDefaults or scattered JSON configuration
After:  owner -> authoritative configuration/state file
```

Coverage limits: real-provider authentication/re-authentication, physical-device protection/backup restore, forced power-loss interruption, and older-writer compatibility are not established by these checks. No downgrade support is implied. Private evidence and the change review remain outside Git.

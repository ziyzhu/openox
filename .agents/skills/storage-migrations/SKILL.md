---
name: storage-migrations
description: Design, implement, review, or verify changes to Ox persisted storage, including filenames, directory layouts, Codable schemas, UserDefaults, Keychain metadata, service repositories, profiles, chats, indexes, and legacy formats. Use whenever a change could affect data written by an older app build or read by a newer one; do not use for transient in-memory state with no persisted representation.
---

# Storage Migrations

Preserve user data across app upgrades. Treat a clean install as insufficient evidence whenever code changes a persisted path, name, identifier, encoding, ownership boundary, or input to derived indexing.

Read [references/storage.md](references/storage.md) before changing or reviewing storage. Update it in the same change whenever a storage location, format, retention rule, backup policy, or owner changes.

## Compatibility boundary

Use `StorageMigrator` as the single startup and activation gate for persisted-format compatibility. Keep every migration entry point, ordered milestone, structural probe, and legacy transform in `apps/ios/Ox/Host/Profile/StorageMigration.swift`; do not introduce domain-specific migrator types or migration files. Consumers must not invoke legacy repair independently or read potentially old state before the gate completes.

Run application-wide migration before constructing storage consumers. Resolve and migrate the active Profile before publishing it to chats, skills, artifacts, or other readers. Prepare the Local service repository before service discovery and search indexing. Apply the same gate before activating another Profile.

Do not expect runtime code to infer arbitrary incompatibilities. Every incompatible change needs an explicit version milestone or an unambiguous structural probe for formats that predate versioning. Reject unknown future versions rather than interpreting them as current data.

## Design a migration

Identify:

- the last shipped representation and every supported legacy representation;
- the authoritative data, derived purgeable data, user-owned working state, and credentials involved;
- the first reader that could observe the new representation;
- whether downgrade compatibility is required, and how partial migration is detected and resumed.

Prefer ordered, retry-safe milestones. Stamp a milestone only after all of its operations succeed. Preserve a recoverable source or equivalent destination across interruption. Define collision behavior explicitly; never replace ambiguous user data. Preserve Local Git history, index state, working-tree changes, and detached views unless the migration specifically and safely transforms them.

Keep a legacy read fallback during the migration window when it materially reduces data-loss risk, but make the migrator responsible for converging storage to the current representation. Derived caches may be invalidated and rebuilt after authoritative migration succeeds.

Log structured detection, start, completion, deferral, and failure events without credentials or reusable secrets. Include the source and target milestone and bounded item counts so TestFlight diagnostics can distinguish absent data from failed discovery or indexing.

## Verify upgrades

Exercise an upgrade fixture produced by the oldest supported shipped representation. Verify:

- first launch migrates before any consumer or indexer reads the state;
- the migrated data is complete and user-owned edits remain intact;
- a second launch is a no-op;
- interruption or unavailable iCloud content defers safely and resumes;
- collisions and unknown future versions fail closed with actionable diagnostics;
- fresh install still works, but is not the only tested path.

Add the smallest sanitized fixture and automated upgrade regression that would have failed before the migration. For Local services, include dirty and clean Git states when relevant. Run the relevant repository checks and exercise the installed iOS build through the startup flow before calling the migration verified.

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

Treat milestone identifiers as immutable persisted data, not editable labels. Once any build, including a local development build, can stamp a milestone, never rename, remove, reuse, or reorder it; append a new milestone and migration instead. A newer build opening a Profile creates a downgrade boundary for every older build that shares that app container.

## Design a migration

Identify:

- the last shipped representation and every supported legacy representation;
- the authoritative data, derived purgeable data, user-owned working state, and credentials involved;
- the first reader that could observe the new representation;
- whether downgrade compatibility is required, and how partial migration is detected and resumed.

Before running another checkout or older build against an existing app container, compare its current schema with the stored milestone. Use an isolated numbered QA simulator or a restored upgrade fixture when they differ. If downgrade compatibility is required, design and verify it explicitly; otherwise fail closed with an actionable message that tells the user to reinstall the version that last opened the data or a newer one.

Prefer ordered, retry-safe milestones. Stamp a milestone only after all of its operations succeed. Preserve a recoverable source or equivalent destination across interruption. Define collision behavior explicitly; never replace ambiguous user data. Preserve Local Git history, index state, working-tree changes, and detached views unless the migration specifically and safely transforms them.

Keep a legacy read fallback during the migration window when it materially reduces data-loss risk, but make the migrator responsible for converging storage to the current representation. Derived caches may be invalidated and rebuilt after authoritative migration succeeds.

Log structured detection, start, completion, deferral, and failure events without credentials or reusable secrets. Include the source and target milestone and bounded item counts so TestFlight diagnostics can distinguish absent data from failed discovery or indexing.

## Verify upgrades

Exercise an upgrade fixture produced by the oldest supported shipped representation. Prefer a snapshot written by the actual predecessor build; a fixture serialized only through current types is not evidence that every shipped representation is covered. Verify:

- first launch migrates before any consumer or indexer reads the state;
- the migrated data is complete and user-owned edits remain intact;
- a second launch is a no-op;
- interruption or unavailable iCloud content defers safely and resumes;
- collisions and unknown future versions fail closed with actionable diagnostics;
- an older build is never installed over data stamped by a newer build during upgrade testing unless the downgrade path is explicitly under test;
- fresh install still works, but is not the only tested path.

Add the smallest sanitized fixture and automated upgrade regression that would have failed before the migration. For Local services, include dirty and clean Git states when relevant. Run the relevant repository checks and exercise the installed iOS build through the startup flow before calling the migration verified.

### Required repository gate

Run this gate after every `StorageMigrator` change, including refactors and diagnostic-only edits:

1. Start one repository server on the port assigned to a numbered QA simulator and verify `/health`.
2. Force-build, install, and launch the DEBUG app on that simulator with matching repository and debug ports.
3. Run `bun run test:storage-migration` against the running app.
4. Run `bun run typecheck` and the smallest domain-specific tests.
5. Confirm the installed app reaches its normal UI and logs `StorageMigrator.prepare done` followed by `IOSHost prepared`.

For `ox-qa-1`, the standard commands are:

```sh
ox repository serve repositories/builtin --port 8101
curl -fsS http://127.0.0.1:8101/health
sim --device ox-qa-1 run ai.oxcraft.bot --project apps/ios/Ox.xcodeproj --scheme ios --env OX_SERVICES_ENDPOINT=http://localhost:8101/repository.git --env OX_DEBUG_ENDPOINT=ws://127.0.0.1:9101 --force
OX_HOST_ENDPOINT=ws://127.0.0.1:9101 bun run test:storage-migration
bun run typecheck
```

Every newly added ordered Profile milestone needs its own directory under `apps/ios/fixtures/storage-migrations/<milestone>/` with complete `before/` and `after/` trees. Derive `before/` from bytes written by the actual predecessor build, sanitize them without changing their encoded shape, and keep the fixture minimal. The replay requires a fixture matching `ProfileSchema.current`, exact post-migration bytes, and exact second-run stability. Never update expected `after/` bytes merely to make a failure green; review the representation change first.

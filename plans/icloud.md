# iCloud Profile snapshots

Draft plan; not implemented. The Profile settings iCloud toggle is removed because the Host rejects moving a live Profile database into iCloud.

## Behavior

Profiles execute locally. iCloud stores closed, consistent snapshots, never a live database. Users explicitly push or pull an entire Profile; there is no automatic synchronization, background push, or merge.

- Push captures a consistent local snapshot and uploads it. A failed or interrupted upload must not replace the last completed remote copy.
- Pull downloads and validates a completed remote snapshot, asks before replacing local content, retains a recovery copy, closes the local storage session, applies the snapshot, and reopens the Profile. Failure must leave the previous local Profile usable.
- The Host owns snapshot capture, validation, transfer, replacement, and recovery. Clients render status, progress, and confirmations.

## UI

Replace the old toggle with explicit push and pull actions. Consider “Save to iCloud” and “Restore from iCloud” as user-facing labels; terminology remains to be confirmed.

Show the remote save time and source device. Explain that changes are not synced automatically and pulling replaces local content rather than combining changes. When no remote snapshot exists, offer only push. Distinguish an absent snapshot from one awaiting download, unavailable iCloud, and a failed transfer.

Before pulling, warn about replacement and provide access to recovery if needed. Before pushing over a changed remote copy, offer cancel, pull, or explicit overwrite.

## Conflicts and recovery

Remember the remote snapshot identifier last pulled or pushed. Check it before pushing; if the remote copy changed, require explicit overwrite confirmation. This check cannot guarantee exclusion of simultaneous writes through iCloud Drive.

Prefer immutable completed snapshots so racing devices and interrupted transfers do not destroy the only usable copy. Define how to select the current snapshot when uploads race, retain older copies, and clean up incomplete uploads before implementation. Do not silently choose a conflicting copy or claim transactional guarantees from iCloud Drive.

Model transfer and replacement states explicitly. Prevent overlapping operations and coordinate local writes so capture and replacement remain consistent. Keep structured on-device diagnostics for operation stages, snapshot identifiers, compatibility checks, and failures without logging Profile content or credentials.

## Snapshot boundary

Audit the existing Profile format before finalizing the payload. Intended portable content: conversations, files, skills, character, memory, and portable Profile settings. Exclude credentials, live service sessions, device permissions, and device-specific paths. A receiving device may need to authenticate and grant permissions again.

Decide whether pull preserves the local Profile identity and how a second device initially imports a remote Profile. Validate snapshot integrity and schema compatibility before replacement; do not partially apply unsupported content.

## Verification and rollout

Verify push/pull on two devices with independent local changes, concurrent pushes, interrupted uploads and replacements, offline operation, delayed iCloud downloads, corrupt snapshots, and recovery. Confirm credentials remain device-local and external folders are not accidentally replaced.

Persisted-format changes require actual predecessor/changed-build evidence in both reader directions, second-launch stability, and maintainer approval for incompatibilities. Keep migration work in the existing scoped migration owners. Until implemented and verified, do not promise live iCloud sync.

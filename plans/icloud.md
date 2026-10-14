# Profile import and export

Manual import/export is implemented. Supersedes the earlier iCloud push/pull proposal. Simulator verification covers round-trip recovery, duplicate names, ordinary writes, restart, an installed predecessor reader, and unsupported backups. Physical iCloud upload/delete/reinstall, interruption stress, large Profiles, and released-predecessor acceptance remain verification gates.

## Scope and UX

Profiles execute locally. Export creates one complete backup file; import creates a new local Profile. The system Files picker supports iCloud Drive, other file providers, and external drives. No automatic backup, synchronization, replacement, or remote snapshot catalog.

- Profile details page: an “Export Profile…” row prepares a backup, then opens Files with a suggested Profile name and date. Show preparation progress, cancellation, completion, and actionable errors.
- Add Profile dropdown menu: “Create new”, “Open existing”, and “Import”. Import opens Files, downloads if needed, validates the backup, and previews its name and date. Confirm a new local name, resolve duplicate names without overwriting, and offer to open the imported Profile.
- Explain: “Profiles stored on this device are removed when you delete Ox. Export a copy to keep them.” Recovery includes only data captured at export time. Credentials and device permissions require setup again.
- Saving inside Ox's own folder does not protect against deletion. Picker completion does not prove an iCloud upload has finished; do not claim cloud protection from that alone.
- Localize English and Simplified Chinese copy, apply stable automation identifiers to controls, use equal outer padding, and show screenshots for review.

## Snapshot boundary

Audit storage before selecting the archive format. Public Profile folders alone are insufficient: private state.sqlite under Application Support/Profiles/<uuid> contains conversations and settings.

Include conversations, retained file history, public files, skills, voice/character, memory, and portable Profile settings. Inventory all historical payload dependencies. Exclude credentials, live sessions, device bookmarks and permissions, active locks, temporary conversations, migration staging, and app-wide settings/diagnostics. Explain external-folder exclusions.

Use one recognizable backup file with a versioned manifest, creation date, display name, compatibility information, and integrity metadata. Define archive limits and sensitive-content disclosure before implementation. Prefer preserving existing live storage formats; do not change the service manifest schema.

## Implementation sequence

1. Reproduce local-only recovery limits using disposable data. Capture predecessor build-written fixtures outside Git. Audit Pi snapshot facilities, identity references, and file dependencies.
2. Implement Host-owned capture through existing storage owners. Coordinate all writers, settle or block active operations, close/checkpoint storage as required, and capture private state plus public files consistently. Resume the original Profile after success, cancellation, or failure. Never independently copy an active database and its files.
3. Package into temporary storage. Clients present Files; Hosts own snapshot integrity and persistence. Reference Apple document import/export and security-scoped URL documentation during implementation. Keep platform adapters within their app directories.
4. Import into isolated staging. Validate compatibility, integrity, required files, archive paths, links, and size limits. Allocate a new identity and remap identity-bound records through existing scoped owners. Publish public/private state using existing recovery machinery; failure leaves existing Profiles untouched. Never automatically resume imported pending actions or schedules.
5. Connect UI and structured diagnostics for stages, durations, sizes, compatibility decisions, and failures without logging content or credentials. Clean up temporary files after picker use and recover interrupted imports at startup.

## Verification

Use E2E coverage, not new unit tests. Round-trip conversations, attachments, historical files, skills, memory, and settings. Verify duplicate names, credential exclusion, original Profile preservation, second-launch stability, and renewed external permissions.

Exercise active writes, cancellation, low storage, process termination, interrupted publication, corrupt/unsupported archives, unsafe archive entries, unavailable providers, offline access, and delayed iCloud downloads.

On a disposable real-device installation, export to iCloud Drive, independently confirm upload, delete Ox with explicit user confirmation, reinstall, and import. Repeat import on another device with the same Apple Account. Confirm no imported actions execute automatically.

For persisted-format changes, follow the release skill's storage compatibility workflow with actual predecessor/changed-build evidence in both reader directions. Update the canonical storage map and report downgrade incompatibilities for maintainer approval before release. Review LOC, file tree, call stack, and cyclomatic complexity for implementation changes.

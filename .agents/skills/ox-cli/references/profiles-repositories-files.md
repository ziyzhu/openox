# Profiles, repositories, and files

## Update the open Profile

A connection reaches only the Profile active on that device:

```sh
ox --profile <ws-url> profile describe
ox --profile <ws-url> profile inspect --json
ox --profile <ws-url> profile rename --name <name>
ox --profile <ws-url> profile update --memory-file <path>
```

Create, select, and delete Profiles in Ox on the device; connections cannot switch or reach other Profiles. Updates reject running conversations; stop them explicitly first. Name and memory updates use Ox's own persistence, not replacement of `profile.json`. Inspect after a failed update before retrying, because earlier writes may have succeeded.

For offline inspection, discover iCloud Profiles on macOS and select one by directory. Unset `OX_PROFILE_ENDPOINT` for discovery so `profile list` reads folders; an explicit `--profile <path>` selects offline reads without unsetting it:

```sh
env -u OX_PROFILE_ENDPOINT ox profile list [--json]
ox --profile <path> profile memory
ox --profile <path> profile skills [name] [--json]
ox --profile <path> profile files [filename] [--json]
ox --profile <path> profile conversations [id] [--json]
```

Profile inspection is read-only. Reading iCloud Drive may require Files & Folders
permission for the terminal or agent host.

## Inspect service repositories

```sh
ox --repository <path-or-url> repository inspect
ox --repository <path-or-url> repository validate
ox --repository <git-url> repository verify
ox --repository <path-or-url> repository serve [--port 8100]
ox --repository <path-or-url> repository services [domain] [--json]
ox --repository <path-or-url> repository actions <domain> [--json]
ox --repository <path-or-url> repository skills [name] [--json]
```

For live candidate comparison, use `ox vm call ox.repository.conflicts --args '{"purpose":"Compare service sources","service":"<domain>","compare":true}'`. It returns complete per-candidate file hashes and sizes without changing active sources or reloading services. Never use `ox.repository.resolve` merely to compare copies; comparison errors do not establish equality.

Inspect an action's input schema, authentication requirement, and approval
requirement before invoking it.

## Download files

```sh
ox --profile <ws-url> --conversation <id> files download report.pdf --output ./report.pdf
ox --profile <ws-url> --conversation <id> conversation inspect --blocks --json
ox --profile <ws-url> --conversation <id> files download --attachment <attachment-id> --output ./upload.pdf
```

Use an attachment ID from the conversation blocks or a virtual file path such as a conversation-relative file or `mounts/<grant-id>/<file>`. The conversation must be loaded. Downloads preserve the stored bytes, use the Profile's file-read policy and grants, and never overwrite an existing local file. Ox caps downloads at 32 MiB, with existing lower limits where applicable. Managed `app/` files and generated `tmp/` output are not downloadable.

## Connect a repository through Files

```sh
ox --profile <ws-url> files mount --timeout 120000
ox --profile <ws-url> files list --json
ox --profile <ws-url> repository connect mounts/<grant-id>[/subfolder]
ox --profile <ws-url> repository list --json
ox --profile <ws-url> service sync
ox --profile <ws-url> repository disconnect <repository-id>
ox --profile <ws-url> files unmount <grant-id>
```

The device's native picker grants access; a CLI-local path cannot authorize remote access. Connection is explicit and persistent, separate from managed Local. Source must use the current repository version; it is read in place without migration or Git seeding. Current Ox builds expose repository files under `repositories/<repository-id>/...`; only files inside Local are writable through that view. Edit connected repositories through the granted Files mount or your editor, not their read-only repository view. Revocation makes connected services unavailable; disconnect does not delete their files. Grant IDs are stable for one grant and never reused for a new authorization. Mounts belong to the open Profile. Existing grants appear as unassigned until `files assign <id>` or explicit assignment in Profile → Files. No Files service attachment is required. Mounted services follow the grant's Profile. Older builds do not enforce ownership and can discard ownership fields on writes; downgrade requires review.

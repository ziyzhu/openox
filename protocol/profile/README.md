# Profile Protocol

Profile identity, version 1 chat metadata, directory names, and directory ownership are **Normative**. The current `turns.jsonl` and `context.json` encodings are reference-implementation formats documented in `../../docs/STORAGE.md`.

`schema.ts` is the TypeBox source of truth for `profile.schema.json` and `chat.schema.json`.

## Layout

```text
<ProfileName>/
├── profile.json
├── chats/
│   └── <uuid>/
│       ├── chat.json
│       ├── turns.jsonl
│       └── context.json
├── artifacts/
│   ├── .saved.json
│   └── <filename>
├── skills/
│   └── <name>/SKILL.md
├── SOUL.md
└── MEMORY.md
```

The directory name is the profile's display name; the UUID in `profile.json` is its stable identity. The display name is not repeated in `profile.json`. Storage locations and URLs, active-profile state, credentials, device preferences, repository caches, and logs are not portable profile data.

`profile.json` MUST match `profile.schema.json`. `chat.json` MUST match the schema selected by its `schemaVersion`; version 1 is currently the only published version. A Host MUST reject and MUST NOT write a future version it cannot read.

## Chats

Each chat uses its own UUID directory. `turns.jsonl` stores semantic turns and `context.json` is an optional provider-neutral continuation checkpoint. Before publishing changed chat metadata, an implementation MUST durably publish the transcript and any checkpoint the metadata describes. A checkpoint may be accepted only when its schema and recorded digests match the transcript and inputs; otherwise the Host rebuilds derived state.

Provider selection and service attachment can affect continuation, but provider wire messages are derived data rather than portable chat messages.

## Artifacts

Artifacts are flat files. Their basename identity is case-insensitive. `.saved.json`, which has no published version 1 schema, records saved-artifact state, while live references can point to artifacts independently of that index.

Renaming an artifact through the Profile owner MUST rewrite Profile-owned references. External deletion or rename may leave missing references and is not covered by this contract. Imports MUST sanitize names, bound content, and resolve collisions. Writes MUST be atomic and confined to the artifact namespace.

## Versioning and migration

The profile schema version is a string milestone equal to the implementation's exported `PROFILE_SCHEMA_VERSION`. Older versions may be accepted only through an exact, retry-safe migration. A migration stamps the new version only after the entire step succeeds.

Implementations must reject unknown future versions and must not silently downgrade or discard data. Persisted-storage migration and legacy-format handling belong at the implementation's dedicated migration boundary.

# Profile Contract

Status: mixed. `profile.json`, current `chat.json` metadata, and the directory
names in `layout.md` are Normative. Turn and context payloads remain
reference-implementation formats.

`schema.ts` is the source of truth for `ProfileConfigSchema` and
`ChatMetadataSchema`. The generated `profile.schema.json` and `chat.schema.json`
are language-neutral artifacts.

Profile folder names are display names and are not encoded in `profile.json`.
Storage location, backing URL, active selection, credentials, and device state
are not portable Profile metadata.

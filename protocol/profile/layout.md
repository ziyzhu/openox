# Profile Layout

Status: Normative for names and ownership. Payloads without schemas remain reference formats.

A Profile is one directory named for display and identified by the UUID in
`profile.json`.

```text
<ProfileName>/
├── profile.json
├── chats/<uuid>/
│   ├── chat.json
│   ├── turns.jsonl
│   └── context.json
├── artifacts/
│   ├── .saved.json
│   └── <filename>
├── skills/<name>/SKILL.md
├── SOUL.md
└── MEMORY.md
```

Credentials, repository clones, caches, logs, and device preferences are not
portable Profile content.

`profile.json` MUST match `profile.schema.json`. `chat.json` MUST match the
schema selected by its `schemaVersion`; this repository currently publishes
only schema version 1. A Host MUST NOT write a future version it cannot read.

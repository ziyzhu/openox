# Profile Layout

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

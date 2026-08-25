# Chats

Status: `chat.json` metadata is Normative. `turns.jsonl` and `context.json` are not yet standardized.

Each chat directory contains metadata in `chat.json`, one semantic turn per
line in `turns.jsonl`, and an optional provider-neutral continuation checkpoint
in `context.json`.

A save publishes transcript and checkpoint data before metadata that points to
their new state. A checkpoint is accepted only when its schema and transcript
digests match. Otherwise the Host reconstructs context from semantic turns.

Provider selection and service attachment may be recorded for continuation,
but provider wire messages are derived and are not an additional transcript.

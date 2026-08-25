# Virtual Filesystem

Status: Normative namespace and authority rules.

The VM exposes Profile memory, soul, artifacts, skills, selected service
definitions, persisted chats, and user-granted files through virtual paths.
Virtual paths do not reveal backing Host paths.

Authority comes from the mounted entry's source, not its path text or file
contents. Profile skills are writable; system and attached-service skills are
read-only. Service source is read-only except for the editable Local repository.
Chat context checkpoints and unrelated Profile files are not addressable.

Reads and searches are bounded. Writes are atomic and must stay within a
writable mount. The complete current namespace is documented in `docs/VM.md`.

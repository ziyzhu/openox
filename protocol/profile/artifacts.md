# Artifacts

Artifacts are ordinary files in the flat `artifacts/` directory. Their
case-insensitive basename is the stable Profile-local identity. `.saved.json`
records which basenames the user explicitly saved.

Chats refer to live artifact filenames. Renames performed by the Profile owner
rewrite persisted references; external deletion or rename may leave a missing
reference. Imports sanitize names, bound content, and resolve collisions.

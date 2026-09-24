---
name: manage-artifacts
description: Create, inspect, revise, import, rename, present, attach, or delete Profile artifacts, with specialized guidance for Markdown notes and interactive HTML canvases.
---

# Manage Artifacts

Create or change persistent files under `artifacts/` only when the user wants a durable artifact or an existing artifact changed. Read-only inspection needs no durable change. Keep ordinary answers in chat.

Read before replacing, renaming, or deleting an existing artifact. Use `ox.fs.list` and `ox.fs.read` to inspect; `ox.fs.write` to create or replace UTF-8 content; `ox.fs.edit` for targeted text changes; and `ox.fs.delete` for deletion. Use `ox.artifact.import` for a public HTTP or HTTPS resource and `ox.artifact.rename` when chat references must follow a rename. Use `ox.artifact.attach` to add stored content to model context and `ox.artifact.present` to show an existing artifact that was not just written or edited.

Reads return complete text into JavaScript by default. Filter or slice long records before printing. Combined console output retains the last 2,000 lines or 50 KiB, whichever is reached first. If console output is truncated, use its `ox.output.read` reference to retrieve the complete output and inspect the missing portions before claiming a full review. References expire when the chat is unloaded; they are not saved artifacts.

Choose only the guidance needed for content authoring:

- For a responsive visual, interactive tool, chart, comparison, map, or HTML Canvas, read `skills/manage-artifacts/references/canvas.md`.
- For a Markdown note, write or edit one UTF-8 `artifacts/<name>.md` file. Preserve the user's content and add only useful structure. A successful write or edit displays it automatically.
- For listing, reading, importing, attaching, presenting, renaming, or deleting an artifact, proceed without loading a format reference.

Do not claim arbitrary binary content is editable. Import, inspect metadata, attach, present, rename, or delete unsupported formats as the available tools allow. Preserve the requested filename when valid, avoid case-insensitive collisions, and report the final artifact path.

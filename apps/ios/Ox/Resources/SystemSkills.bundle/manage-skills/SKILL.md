---
name: manage-skills
description: Create, inspect, customize, revise, share, or delete reusable skills owned by a Profile or repository.
---

# Manage Skills

Create or change durable skills only when the user requests it. Use memory for personal preferences and complete one-time tasks directly.

All skills execute through the agent in the Ox VM. Use its `ox.*` APIs, virtual filesystem, and normal service Actions. Do not assume a terminal, Node.js, a host filesystem, or authenticated services.

## Discover and resolve

System, enabled repository, and active Profile skills share one catalog. Read `skills/<name>/SKILL.md` to activate a resolved skill. Names have no owner prefix. When a name conflicts, ask the user to choose its source in the Skills library before proceeding. Never select a source on the user's behalf.

System names are reserved. System and installed repository skills are read-only. Profile skills and skills in the Local repository's latest view are editable. Check the source in the library before mutation. A historical Local view is read-only.

## Create and customize

New skills belong to the active Profile by default. Read `references/user-skill.md` for the authoring workflow. Use `ox.skill.create` for the initial instructions, `ox.fs.write` or `ox.fs.edit` for revisions, and `ox.skill.copy` to create an independent Profile copy of any resolved skill. Copying retains references, helpers, and service dependencies.

Each skill directory contains:

- `SKILL.md`: matching name, description, optional comma-separated `services`, and instructions.
- `references/`: optional supporting text loaded as needed.
- `scripts/`: optional JavaScript helpers executed in the current Ox VM.

Use `ox.fs` to read and edit resources. Helpers are async function bodies receiving `ox` and `args`; return a JSON-compatible result. Invoke them with `ox.skill.run({ name, script, args, purpose })`, where `script` is relative to `scripts/`. Helpers use the same Action policies and capabilities as ordinary VM execution.

## Share

Read `references/repository-skill.md` when publishing a skill or editing Local repository content. `ox.skill.share` copies the complete resolved skill into Local and refuses to replace an existing Local name. Review personal information before sharing. Repository publication is an explicit user choice, separate from creating or customizing a Profile skill.

Deleting a skill uses `ox.skill.delete`. Saved invocations and schedules retain their own snapshots. Explain that deletion does not delete those snapshots or their schedules.

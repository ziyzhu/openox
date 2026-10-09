---
name: manage-skills
description: "Create, inspect, customize, revise, copy to Local, or delete reusable skills owned by a Profile or repository."
---

# Manage Skills

Create or change durable skills only when the user requests it. Use memory for personal preferences and complete one-time tasks directly.

All skills execute through the agent in the Ox VM. Use its `ox.*` APIs, virtual filesystem, and normal service Actions. Do not assume a terminal, Node.js, a host filesystem, or authenticated services.

## Discover and resolve

Bundled System skills, enabled repository skills, and active Profile skills share one catalog. Read `skills/<name>/SKILL.md` to activate a resolved skill. Names have no owner prefix. System names always resolve to the trusted bundled skill and cannot be shadowed by Profile or repository content. Other conflicts require the user to choose a source in the Skills library; never select one on their behalf.

Bundled System skills are read-only. Copy one to a distinct, nonreserved name to customize it; the copy is a Profile skill, not trusted System policy. Installed repository skills are read-only. Profile skills and skills in the Local repository's latest view are editable. Check the source in the library before mutation. A historical Local view is read-only.

## Create and customize

New skills belong to the active Profile by default. Read `references/user-skill.md` for the authoring workflow. Use `ox.skill.create` for the initial instructions, `ox.fs.write` or `ox.fs.edit` for revisions, and `ox.skill.copy` to create an independent Profile copy of any resolved skill. Copying retains references, helpers, and service dependencies.

Each skill directory contains:

- `SKILL.md`: matching name, description, optional comma-separated `services`, and instructions.
- `references/`: optional supporting text loaded as needed.
- `scripts/`: optional JavaScript helpers executed in the current Ox VM.

Use `ox.fs` to read and edit resources. Helpers are async function bodies receiving `ox` and `args`; return a JSON-compatible result. Invoke them with `ox.skill.run({ name, script, args, purpose })`, where `script` is relative to `scripts/`. Helpers use the same Action policies and capabilities as ordinary VM execution.

## Local repository

Read `references/repository-skill.md` when copying a skill to Local or editing Local repository content. `ox.skill.share` copies the complete resolved skill into Local and refuses to replace an existing Local name. Review personal information before copying Profile content into Local.

Deleting a skill uses `ox.skill.delete`. Saved invocations and schedules retain their own snapshots. Explain that deletion does not delete those snapshots or their schedules.

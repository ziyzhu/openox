---
name: manage-skills
description: Create, inspect, revise, copy, or delete Profile-owned and Local service-owned skills while respecting read-only system and external service skills.
---

# Manage Skills

Manage reusable agent workflows only when the user explicitly asks for a durable skill change. Default to doing one-time tasks directly and keep durable preferences in memory.

Identify ownership before mutation:

- Profile-owned skills live at `skills/<name>/SKILL.md` and support create, read, update, copy, and delete.
- System skills under `skills/system:<name>/` are read-only. They may be read or copied into a new Profile-owned skill with `ox.skill.copy`.
- Attached service skills under `skills/service:<domain>:<name>/` are read-only mounted guidance. A service skill can be changed only in editable Local source under `services/web/<domain>/skills/<name>/SKILL.md`, with a matching manifest declaration. Copy a non-Local service to Local with approval before editing it.

Use `ox.fs.glob` and `ox.fs.read` to inspect. Use `ox.skill.create` for a new Profile skill, `ox.fs.edit` for focused Profile-skill revisions, `ox.skill.copy` for a new Profile-owned copy, and `ox.skill.delete` for a Profile-skill deletion. Read the relevant source and manifest before changing a Local service skill.

Load only the ownership-specific workflow needed:

- For designing, creating, or substantially revising a Profile-owned skill, read `skills/system:manage-skills/references/user-skill.md`.
- For creating, substantially revising, or deleting a Local service-owned skill, read `skills/system:manage-skills/references/service-skill.md`.
- For listing, reading, copying, or deleting a Profile-owned skill, proceed without loading a reference.

If a service action is missing or broken, read `skills/system:manage-services/SKILL.md` before writing service-skill guidance. Keep one skill focused on one trigger and one outcome, validate its activation boundary, and verify the final mounted form after mutation.

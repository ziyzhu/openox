# Service Skill

Create a service skill when one service needs reusable reasoning or a multi-action workflow that its action schemas cannot express. The skill travels with that service and becomes available as `service:<domain>:<name>` whenever the service is attached.

```text
services/web/<domain>/
├── service.json
└── skills/<name>/SKILL.md
```

Use a user skill instead when the workflow belongs to the Profile, combines multiple services, or primarily captures the user's preferences. Read `skills/system:manage-services/SKILL.md` first when actions are missing or need repair.

## 1. Establish the service contract

1. Find and attach the target service.
2. Read its manifest and inspect complete schemas for every relevant action.
3. Read its existing service skills through `skills/service:<domain>:<name>/SKILL.md` or Local source paths.
4. Copy a Bundled, Development, or Remote web service to Local with approval when editable source is needed.
5. Inspect Local Git status and return to `latest` when viewing history.

Use only capabilities the current manifest exposes. Finish action implementation and verification before designing guidance around it.

## 2. Decide the skill boundary

Create a service skill for reusable work such as:

- Coordinating several actions toward one outcome.
- Refining queries and deciding what evidence to inspect next.
- Comparing results, checking counterevidence, or assessing source credibility.
- Applying service-specific safety, quality, or stopping rules.
- Producing a stable synthesis or handoff format.

Keep a direct action call, field explanation, one-time request, or personal preference outside the service skill.

Give one skill one trigger and one outcome. Test the proposed trigger against two realistic requests that should activate it and one boundary request that should use the service directly.

## 3. Present the design

Present:

```text
Service:
Name:
Runs when:
Inputs:
Workflow:
Actions used:
Output:
Stopping rule:
Safety boundaries:
```

Then call `ox.user.choose` with `Create skill`, `Revise proposal`, and `Cancel`. Write only after `Create skill`; revise and present the checkpoint again when requested.

## 4. Write the Local source

Use a short lowercase kebab-case name without a namespace. Write only `services/web/<domain>/skills/<name>/SKILL.md` with matching `name` and `description` as its only frontmatter fields:

```markdown
---
name: research
description: Research this service's content with source and credibility checks
---

Build focused searches...
```

Write the body as an execution prompt with imperative steps, decision rules, exact exposed action IDs, user checkpoints, output requirements, safety boundaries, and a stopping condition. Keep endpoint mechanics, attachment instructions, one-time details, and unsupported capabilities outside the skill.

For a new skill:

1. Write the valid `SKILL.md` source first.
2. Add `{ "name": "<name>", "description": "<description>" }` to the manifest's `skills` array while preserving existing entries.

For a revision, read both files and keep the manifest description aligned with the skill frontmatter. Use `ox.fs.edit` for focused changes.

For deletion, read the skill file and manifest, remove the matching manifest declaration, delete `services/web/<domain>/skills/<name>/SKILL.md`, and verify that no stale declaration or file remains. Show the affected paths before any broad restore if the deletion is abandoned.

## 5. Verify activation

1. Read the resulting manifest and any remaining changed skill source back.
2. Confirm every named action still exists and its schema supports the instructed use.
3. Confirm the manifest declares each skill once and every declaration has a matching valid file.
4. Call `ox.service.validate({ domain, purpose })`, fix any errors, then `ox.service.attach({ domain, purpose })` to reload the current source. File edits alone do not update mounted skills.
5. Confirm the Local service is attached and discoverable.
6. For creation or revision, read `skills/service:<domain>:<name>/SKILL.md` and compare it with the final source; recheck the trigger and boundary examples. For deletion, prove the declaration, source file, and mounted skill are absent.

## 6. Review and save

Inspect complete Local Git status and diff. Confirm only intentional skill, manifest, and related edits are included. Ask the user to **Save** the skill changes, with a purpose such as `Save research skill`. After approval, use Local Git internally to persist them; keep Git and revision mechanics internal unless the user asks or recovery requires them.

Report the saved skill name, trigger, actions used, verified boundaries, and remaining limitations. For deletion, report the removed skill instead. Mention source files or revisions only when requested.

If manifest registration fails after creating a new file, correct the manifest and retry. If the draft is abandoned, show every pending Local path before requesting approval for a full Local restore.

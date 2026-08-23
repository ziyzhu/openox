---
name: create-service-skill
description: Create or revise reusable agent guidance owned by one Ox Local web service after its action surface exists.
---

# Create a Service Skill

Create a service skill when one service needs reusable reasoning or a multi-action workflow that its action schemas cannot express. The skill travels with that service and becomes available as `service:<domain>:<name>` whenever the service is attached.

```text
services/web/<domain>/
├── manifest.json
└── skills/<name>/SKILL.md
```

Use a user skill instead when the workflow belongs to the Profile, combines multiple services, or primarily captures the user's preferences. Use `system:create-web-service` first when actions are missing or need repair.

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

## 5. Verify activation

1. Read the final source file and manifest back.
2. Confirm every named action still exists and its schema supports the instructed use.
3. Confirm the manifest declares each skill once and every declaration has a matching valid file.
4. Confirm the Local service remains attached and discoverable.
5. Read `skills/service:<domain>:<name>/SKILL.md` to prove the service skill is available in this chat.
6. Recheck the two trigger examples and the boundary example against the final description and instructions.

## 6. Review and commit

Inspect complete Local Git status and diff. Confirm the change contains the skill file and matching manifest registration, plus only intentional related edits. Commit with approval and a concise message describing the workflow added and why.

Report the mounted skill name, trigger, actions used, verified boundaries, committed files, and remaining limitations.

If manifest registration fails after creating a new file, correct the manifest and retry. If the draft is abandoned, show every pending Local path before requesting approval for a full Local restore.

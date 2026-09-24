# User Skill

Default to doing the task directly. Create a user skill when the user wants a recurring workflow with variable inputs and a stable outcome. Keep durable preferences in memory. Use this guidance for creating or substantially revising a Profile-owned skill; the manager entrypoint covers simple reads, copies, and deletions.

One skill owns one trigger and one outcome. Split independent triggers or outputs into separate skills.

## Understand the workflow

Establish through concrete examples:

- What starts the workflow and what input may vary.
- The ordered steps, decisions, and user checkpoints.
- The expected output and its success criteria.
- Important failure, privacy, and safety boundaries.

Ask one decisive question at a time when its answer changes the reusable workflow. Use `ox.user.choose` with 2–4 likely answers; its custom-answer path covers anything else. Stop once the workflow can be explained without inventing consequential details.

Inspect existing user skills with `ox.fs.glob` and `ox.fs.read` to avoid duplicate names or overlapping instructions. When adapting an existing Profile, `system:`, or `service:` skill, use `ox.skill.copy` to create the Profile-owned starting point.

## Validate the design

Test the trigger and workflow against two realistic requests that should use the skill and one boundary request that should not. Tighten ambiguous triggers, inputs, outputs, or stopping conditions.

## Choose services

Identify the external capability needed by each step. Search with `ox.service.find`, read the strongest candidates at their returned `manifestPath`, and compare their domains, descriptions, and actions.

Recommend the smallest useful set of service domains. An empty set is valid. Explain what each service contributes and let the user add, remove, or replace services.

Present this checkpoint before writing:

```text
Name:
Runs when:
Inputs:
Workflow:
Output:
Services:
```

Then call `ox.user.choose` with `Create skill`, `Revise proposal`, and `Cancel`. Write only after `Create skill`. Revise and present the checkpoint again when requested.

## Write the skill

Use a short lowercase kebab-case name. The `system:` and `service:` namespaces are reserved. Create the accepted skill with `ox.skill.create`, passing its name, description, instructions, and service domains. This writes one canonical `skills/<name>/SKILL.md` file:

```markdown
---
name: weekly-review
description: Prepare a concise weekly review
services: example.com
---

Review completed work...
```

Omit `services` when the set is empty. Store accepted service domains only in frontmatter.

Write the body as an execution prompt. Use imperative steps, decision rules, the required output shape, checkpoints, and stopping conditions. Keep one-time task details and attachment mechanics outside the skill.

The skill may use available `ox.*` functions. Its runtime has no shell, filesystem outside Ox's virtual layout, bundled resources, scripts, package installation, browser globals, or ambient network access.

Read an existing file before replacing it and prefer `ox.fs.edit` for focused revisions. Read the final skill back and verify its name, description, services, instructions, and trigger boundaries against the accepted proposal. Use `ox.skill.delete` when the user asks to remove a Profile-owned skill.

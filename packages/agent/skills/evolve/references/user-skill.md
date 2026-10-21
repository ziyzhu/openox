# User Skill

Default to doing the task directly. Create a user skill when the user wants a recurring workflow with variable inputs and a stable outcome. Keep durable preferences in memory. Use this guidance for creating or substantially revising a Profile-owned skill; the manager entrypoint covers simple reads, copies, and deletions.

One skill owns one trigger and one outcome. Split independent triggers or outputs into separate skills.

## Understand the workflow

Establish through concrete examples:

- What starts the workflow and what input may vary.
- The ordered steps, decisions, and user checkpoints.
- The expected output and its success criteria.
- Important failure, privacy, and safety boundaries.

Infer the workflow from the request, memory, and existing skills. Ask only if a consequential detail cannot be inferred, using `ox.user.choose` with 2–4 likely answers.

Inspect existing user skills with `ox.fs.glob` and `ox.fs.read` to avoid duplicate names or overlapping instructions. When adapting an existing Profile or repository skill, use `ox.skill.copy` to create the Profile-owned starting point.

## Validate the design

Test the trigger and workflow against two realistic requests that should use the skill and one boundary request that should not. Tighten ambiguous triggers, inputs, outputs, or stopping conditions.

## Choose services

Identify the external capability needed by each step. Search with `ox.service.find`, read the strongest candidates at their returned `manifestPath`, and compare their domains, descriptions, and actions.

Choose the smallest useful set of service domains from verified capabilities; an empty set is valid. Reuse established workflow requirements and proceed without a separate proposal or creation confirmation. Ask only when a consequential choice cannot be inferred from the request and observed evidence.

## Write the skill

Use a short lowercase kebab-case name. Bundled System names are reserved. Other duplicate names require a source selection. Create the skill with `ox.skill.create`, passing its name, description, instructions, and service domains. This writes one canonical `skills/<name>/SKILL.md` file:

```markdown
---
name: weekly-review
description: Prepare a concise weekly review
services: example.com
---

Review completed work...
```

Omit `services` when the set is empty. Store verified service domains only in frontmatter.

Write the body as an execution prompt. Use imperative steps, decision rules, the required output shape, checkpoints, and stopping conditions. Keep one-time task details and attachment mechanics outside the skill.

The skill may use available `ox.*` functions and packaged resources under `skills/<name>/references/` and `skills/<name>/scripts/`. Read references with `ox.fs.read`; run JavaScript helpers with `ox.skill.run` under normal Action policies. Its runtime has no shell, filesystem outside Ox's virtual layout, package installation, browser globals, or ambient network access.

Read an existing file before replacing it and prefer `ox.fs.edit` for focused revisions. Read the final skill back and verify its name, description, services, instructions, and trigger boundaries against the task requirements and observed workflow. Use `ox.skill.delete` when the user asks to remove a Profile-owned skill.

Copying, sharing, and scheduling a skill must preserve its complete resources. Repository updates never modify independent Profile copies. Use a distinct name or have the user select a source when a name conflicts.

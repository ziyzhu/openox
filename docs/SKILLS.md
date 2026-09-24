# Repositories and skills

A repository shares services, skills, or both:

```text
repository.json
skills/
  research/
    SKILL.md
    references/guide.md
    scripts/run.js
web/<domain>/
  service.json
  actions.js
api/<id>/service.json
mcp/<id>/service.json
```

```json
{"version":3,"name":"My Repository","services":["web:example.com"],"skills":["research"]}
```

Services contain their Actions and implementation. Skills live at the root and may
use multiple services. A repository with only skills has an empty `services` array.

## One package format, three owners

| Owner | Storage | Editing |
| --- | --- | --- |
| System | App bundle | Read-only; reserved names |
| Repository | Root `skills/<name>/` | Local is editable; other repositories are read-only |
| User | Profile `skills/<name>/` | Editable; follows the Profile |

All three use the same parser, catalog, resource mount, and invocation format.
Discovery includes enabled repository skills before their services are attached.
The agent sees names and descriptions, then reads `skills/<name>/SKILL.md` to
activate a package. Instructions guide normal service discovery and attachment.

Duplicate names require a source choice in the Skills library. Choices belong to
the Profile, include user-versus-repository conflicts, and survive reloads. A
missing chosen source does not silently switch to another implementation. Public
paths and slash commands never need an ownership prefix.

## Authoring

```markdown
---
name: research
description: Research a topic with cited evidence.
services: example.com
---

Read references/guide.md before researching. Use the attached service Actions.
```

Frontmatter uses one-line fields; quote descriptions with JSON string syntax when
needed. A package may include nested UTF-8 references and `.js` helpers, up to
64 files and 512 KiB total. Symlinks, traversal, and other resource roots are rejected.

Skills assume the Ox VM. Helpers are async function bodies receiving `ox` and
`args`, invoked with `ox.skill.run({name, script, args, purpose})`. They have the
same filesystem boundaries and Action policies as other VM code. They do not
have Node, a terminal, or direct host filesystem access.

Customize creates an independent Profile copy including all resources. Add to
Local Repository copies the package into Local for Git review. Commit it with
`ox.repository.git.commit`; a reviewed publication proposal can include services,
skills, or both through `ox.repository.propose`. `.skill` import/export also
preserves the complete package.

Reading a package freezes it for the current run. Scheduled invocations store a
complete package snapshot, so later edits and repository updates cannot change
an existing schedule.

## Compatibility

Repository format 3 retires nested service skills. `StorageMigrator` converts old
packages, preserves Local Git history and unfinished changes, and normalizes
historical views without rewriting their commits. Unequal name collisions stop
conversion and retain the originals for recovery. Profile migrations rewrite old
skill paths and repository API names in saved skill instructions. See the
[storage reference](../.agents/skills/storage-migrations/references/storage.md).

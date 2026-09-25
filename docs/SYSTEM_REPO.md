# System repository

Ox should ship its built-in services and system skills in one repository package.
This is a packaging decision, not a change to skill ownership or the repository
format. The existing version 3 `repository.json` already declares both `services`
and root-level `skills`.

## Current layout

- `repositories/builtin/` is the source for built-in services. Its manifest has
  an empty `skills` array. `bun run build:services` generates
  `apps/ios/Ox/Resources/OxServices.bundle` from it.
- `apps/ios/Ox/Resources/SystemSkills.bundle` separately contains
  `manage-artifacts`, `manage-services`, and `manage-skills`.
- `BuiltInSkills` loads the separate skill bundle as system-owned packages.
  The repository loader loads enabled repository skills as repository-owned
  packages. Bundled services can be disabled without disabling system skills.

## Target layout

```text
repositories/builtin/
  repository.json
  skills/
    manage-artifacts/SKILL.md
    manage-services/SKILL.md
    manage-skills/SKILL.md
  ios/<id>/service.json
  web/<domain>/service.json
  web/<domain>/actions.js
```

The generated app bundle contains the same repository structure, with the three
names declared in `repository.json` alongside the service IDs. Skill references
remain inside their respective skill directories. The repository build validates
and copies both kinds of package. The separate `SystemSkills.bundle` goes away.
The generated bundle can keep its current `OxServices.bundle` path during this
change; a later rename would only clarify its broader contents.

## Runtime contract

- Load declared skills from the bundled repository as **system** skills, even
  when bundled services are disabled. They remain read-only and their names
  remain reserved. Other repositories and Profiles cannot claim those names.
- Continue to resolve system, repository, and Profile skills through the same
  catalog and `skills/<name>/SKILL.md` virtual paths. Keep system skills
  available without attaching any service.
- Treat the bundled repository as the sole source of these packages. Do not
  expose a second repository-owned copy of a system skill in the catalog.
- Keep the normal repository validator's reserved-name rejection for Local and
  installed repositories. Only the trusted built-in build and loader may accept
  declared system skill names.
- Preserve saved skill names and paths so Profile instructions, chat references,
  and scheduled skill snapshots continue to work. A later rename would need a
  separate storage migration and compatibility review.

Moving files into the repository without changing the loader is insufficient:
the current repository loader gives bundled skills repository ownership and
skips them when that repository is disabled.

## Skill entrypoints

Keep the three current entrypoints for this packaging change. `manage-artifacts`
has substantial artifact-specific guidance; `manage-services` also covers direct
MCP connections that are not repository packages. Combining them into
`manage-profiles` and `manage-repositories` would broaden their triggers and
require a separate workflow and naming review. If Profile work is grouped later,
`manage-profile` describes the active Profile more precisely than the plural.

## Implementation checks

Update the bundle build and system skill validation to read from
`repositories/builtin/skills/`. Verify that all declared system packages are
present in the generated bundle, retain system ownership and reserved names,
remain available when bundled services are disabled, and appear once in the
skill catalog. Run the service bundle build and relevant skill checks before
shipping the change.

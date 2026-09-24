# Repository Skills

Repository skills live at the repository root under `skills/<name>/`. The repository manifest declares their names alongside its services. A repository can contain services, skills, or both. Services do not own skills.

Use `ox.skill.share({ name, purpose })` to copy a complete resolved skill into Local. This creates editable repository content without publishing it. If Local already contains the name, inspect the existing skill and agree on a revision or another name instead of replacing it implicitly.

A skill's optional `services` field lists runtime service identities. Dependencies may come from any enabled repository. Loading the skill does not grant permission, authenticate accounts, or bypass service conflicts. Discover and attach dependencies through normal Ox APIs before invoking their Actions.

Review the skill's trigger, inputs, steps, expected result, and stopping condition. Verify every named Action against the current service manifest. Keep account details and personal preferences in the Profile rather than shared instructions.

If another source provides the same skill name, ask the user to select Local in the Skills library before testing Local content. Read back `skills/<name>/SKILL.md`, references, and helpers. Exercise the workflow in Ox and verify its result.

Review `ox.repository.git.status` and `ox.repository.git.diff`. Save the verified Local changes with `ox.repository.git.commit` when the user authorizes saving. A Local historical view is read-only; return to latest before editing.

For explicit publication, call `ox.repository.propose` with a saved commit, `skills: [name]`, and any selected `services`. Either list may be empty, but select at least one item. Describe the intended behavior and verification in the proposal. Ox handles publication credentials through secure UI.

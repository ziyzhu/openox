# Reusable Skills

Create or improve a skill when the user requests one or the task requires it. Improve relevant existing skills before creating overlapping ones. Finish ordinary requests directly without creating a skill solely because the work could be reused. Keep personal preferences in memory and one-time task details out of skills. Continue authoring and verification without a proposal checkpoint; ask only for consequential missing decisions. Scheduling still requires an explicit request.

All skills execute through the agent in the Ox VM. Use its `ox.*` APIs, virtual filesystem, and normal service Actions. Do not assume a terminal, Node.js, a host filesystem, package installation, browser globals, ambient network access, or authenticated services.

## Discover and resolve

Bundled System skills, enabled repository skills, and active Profile skills share one catalog. Read `skills/<name>/SKILL.md` to activate a resolved skill. Names have no owner prefix. System names always resolve to the trusted bundled skill and cannot be shadowed by Profile or repository content. Other conflicts require the user to choose a source in the Skills library; never select one on their behalf.

Bundled System skills are read-only. Copy one to a distinct, nonreserved name to customize it; the copy is a Profile skill, not trusted System policy. Installed repository skills are read-only. Profile skills and skills in the Local repository are editable. Check the source in the library before mutation. Local edits persist immediately; there is no separate Save step or built-in version history.

## Author a Profile skill

New skills belong to the active Profile by default. Give each skill one trigger and one outcome. Establish its variable inputs, ordered steps, decisions, checkpoints, expected output, success criteria, and failure and privacy boundaries from concrete examples. Use the request, memory, and existing skills to resolve details. Ask only about consequential gaps, using `ox.user.choose` with 2–4 likely answers. Check the design against two requests that should trigger the skill and one that should fall outside it.

Inspect existing skills with `ox.fs.glob` and `ox.fs.read` to avoid overlapping instructions. Use `ox.skill.copy` as the starting point when adapting an existing skill into a Profile skill. Identify the external capabilities the workflow needs, inspect existing service contracts, and use Evolve to build or repair missing actions before verification. Choose the smallest verified set of dependencies. A workflow can have zero service dependencies.

Use `ox.skill.create` with a short lowercase kebab-case name, description, instructions, and verified service domains when applicable. In the description, state when the skill should trigger and any important boundary. In the body, give Ox imperative steps, decision rules, output shape, checkpoints, and observable stopping conditions. Keep domain-specific guidance and put conditional detail in references with explicit loading triggers.

Read the existing file before using `ox.fs.write` for a replacement. Prefer `ox.fs.edit` for targeted revisions. Read the finished skill back and verify the name, description, services, instructions, and trigger and outcome against the request and the observed workflow.

## Skill files and copies

Each skill directory contains:

- `SKILL.md`: frontmatter with matching `name`, `description`, and optional comma-separated `services`, followed by instructions. Omit `services` when empty.
- `references/`: optional supporting text loaded as needed.
- `scripts/`: optional JavaScript helpers executed in the current Ox VM.

Use `ox.fs` to read and edit resources. Helpers are async function bodies receiving `ox` and `args`; return a JSON-compatible result. Invoke them with `ox.skill.run({ name, script, args, purpose })`, where `script` is relative to `scripts/`. Helpers use the same Action policies and capabilities as ordinary VM execution.

Use `ox.skill.copy` to create an independent Profile copy of any resolved skill. Copying, sharing, and scheduling preserve the full package, including references, helpers, and service dependencies. Repository updates leave independent Profile copies intact.

Use `ox.skill.delete` when the user requests deletion. Saved invocations and schedules retain their own snapshots and remain after deletion.

## Local repository

Repository skills live at the repository root under `skills/<name>/`. The repository manifest lists skill names alongside service registrations. Services and skills are independent. Service dependencies can come from any enabled repository. Inspect their current contracts before invoking actions under normal authentication and Action policies. The Host loads current valid source on demand.

Use `ox.skill.share({ name, purpose })` to copy the full package into Local as editable repository content. Review it for personal details before sharing. If the name already exists in Local, inspect the existing skill and agree on a revision or another name. If sources conflict, ask the user to select Local in the Skills library before testing it.

Read back the full Local package, verify each named action against the current manifest, and exercise the workflow in Ox to confirm the result. Preserve unrelated packages and existing source.

## General Rules

1. The app must remain neutral to LLM provider.
1. When OpenOx functionality uses OAuth, use apps registered as OpenOx.
1. Logs are user-owned on-device diagnostics.
1. Keep enough structured logs to diagnose production issues.

## Coding Rules

1. Do not use code comments; communicate through code.
1. Prefer small, simple changes; consider refactoring as you work.
1. Prefer composition over inheritance, using helpers, extensions, or owned collaborators.
1. Model state explicitly; prefer state machines that make illegal states unrepresentable over scattered booleans.
1. Always work on `main`.
1. Keep documentation minimal; prefer code as the source of truth; avoid nested sections in md.
1. Improve existing user/project skills or steering files when you identify useful lessons.
1. AGENTS.md should not reference skills, vice versa, they should stay independent.
1. Do not invent new concepts unless the user confirms.
1. Do not introduce new abstractions without permission for simple changes.

## Architecture and Storage

1. Hosts own `ox.*` execution, capability enforcement, service sessions, credentials, schedules, and persistence; implement platform-supported capabilities through owned collaborators. Clients own rendering, input, theme, and local feedback. Host-requested interaction must not depend on the iOS Client; retain client-local API behavior only as explicit compatibility.
1. Keep iOS and macOS implementations independent under their app directories. Put platform-neutral runtime code and resources in `apps/shared`; neither app may compile the other's sources. Select platform adapters through target source membership, not OS conditionals. Duplication is acceptable for platform-specific behavior.
1. Use files, not artifacts, in current UI, model-facing prose, and runtime type names. Do not expose `ox.artifact.*` helpers. Preserve artifact identifiers only at persisted-data and wire-format boundaries.
1. Keep model-facing guides self-contained and free of external links; explain required concepts inline.
1. Keep agent prompts and bundled System skills in `packages/agent`; use the normal skills catalog and package layout, scoped resource/capability contracts, and runtime permissions independent of skill activation instead of a separate guidance inventory or mount.
1. Keep the three feature headings and descriptions identical across `README.md`, `apps/ios/Client/Features/Onboarding/OnboardingView.swift`, and the website at `../openox-dev/web/index.html`; update the onboarding translations when this copy changes.
1. Keep persisted-storage migration and legacy-format handling in scoped migration owners: `ProfileMigrator`, `ConversationMigrator`, `ApplicationStorageMigrator`, `CredentialMigrator`, and `RepositoryMigrator`. Keep `StorageMigrator` as the ordered startup/recovery coordinator; recover Profile publications before discovery and prepare storage before runtime consumers read it. Preserve milestone identifiers, journals, and failure policies when refactoring.
1. Persisted-storage changes require actual predecessor/changed-build evidence for newer readers with older data and older readers with newer data. Report incompatibilities and obtain maintainer approval before release; safe rejection is not full compatibility.
1. Pi Durable owns conversation database migrations. For OpenOx document schema changes, increment the owning `defineDoc.version` and provide `migrate(value, fromVersion)` covering every supported predecessor; preserve custom entry payload compatibility. Keep legacy conversation conversion in `ConversationMigrator`.
1. Do not modify the service manifest schema without maintainer approval.

## UI and Assets

1. UX must hold up across supported devices and use equal outer-edge padding.
1. Always require user confirmation before destructive actions, except service actions whose approval is governed by the user's Action policies; use that policy mechanism instead of adding a separate confirmation.
1. Shared interactive UI components must require stable automation identifiers and apply them to the actual controls. Use `oxSearchable` for native search fields; repeated controls must derive unique identifiers from their stable item IDs.
1. Reference Apple development documentation for iOS changes.
1. Prefer springs configured with duration and bounce for movement and gesture settling; start with zero bounce and tune duration in context. See [Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/).
1. Use perceptual animation completion (`.logicallyComplete`) for user-facing handoffs unless full animation removal is required; do not infer spring completion from a fixed delay.
1. Keep temporary screenshots, recordings, traces, and diagnostics outside the repository.
1. App Store Connect owns listing metadata and media; do not keep local copies in either repository. Keep release credentials, signing material, review contacts, demo access, and evidence outside Git. Website and infrastructure deployment belong in `openox-dev`.
1. Hosted service and model-provider icons live only in the `openox-service-assets-prod` S3 bucket, served at `https://openox.ai/assets/services/`; do not keep local copies. Upload reviewed icons directly and verify the anonymous hosted bytes.

## Verification and Review

1. Reproduce the issue first before attempting to fix it so that you can verify the fix.
1. Do not add unit tests; prefer E2E tests.
1. For each commit, review lines of code and cyclomatic complexity, prefer low.
1. For each commit, review the performance implications.
1. For each change review, show the lines-of-code (LOC) delta, file tree diff, and call stack diff; mark non-applicable diffs explicitly.
1. For UI change reviews, capture screenshots or videos from the simulator as appropriate and share them with the user for visual review.

## Commit Rules

1. Do not include `Co-Authored-By` trailers in commit messages.
1. Use the commit message template below with a short imperative subject. Describe the changes and testing performed; include related issues, pull requests, or commits, or write `None` when there are no related references. State when testing was not run and why.
1. Committing does not require iOS version checks, App Store Connect queries, version bumps, or version tags in commit messages.

```text
<imperative summary>

Changes:
- <what changed and why>

Testing:
- <checks performed and results>

Related:
- <related references or None>
```

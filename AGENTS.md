## General Rules

1. The app must remain neutral to LLM provider.
1. Logs are user-owned on-device diagnostics.
1. User data is allowed in logs; credentials and reusable secrets are not.
1. Keep enough structured logs to diagnose production issues.
1. Prefer composition, explicit state, and small changes.
1. Use Action/actions consistently for Ox functionality in iOS UI copy, data models, and protocols. Preserve Apple's Shortcuts action terminology.
1. Use `.agents/skills/storage-migrations` for changes that affect persisted data or storage layout.
1. Keep all persisted-storage migration and legacy-format handling behind `StorageMigrator` in `apps/ios/Ox/Host/Profile/StorageMigration.swift`; do not add other migrator types or migration files.
1. Do not modify the service manifest schema without maintainer approval.
1. UX must hold up across supported devices and use equal outer-edge padding.
1. Reference Apple development documentation for iOS changes.
1. Prefer springs configured with duration and bounce for movement and gesture settling; start with zero bounce and tune duration in context. See [Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/).
1. Use perceptual animation completion (`.logicallyComplete`) for user-facing handoffs unless full animation removal is required; do not infer spring completion from a fixed delay.
1. Keep temporary screenshots, recordings, traces, and diagnostics outside the repository.

## Review Rules

1. For each commit, review lines of code and cyclomatic complexity, prefer low.

## Commit Messages

1. Include the current iOS marketing version in every commit subject using `<imperative summary> (iOS <version>)`, including commits that do not modify the iOS app.
1. Before committing, use `asc apps list --bundle-id ai.oxcraft.bot` to resolve the App Store Connect app and `asc versions list --app <app-id> --platform IOS` to inspect its iOS versions and states.
1. Treat the highest version in `READY_FOR_DISTRIBUTION` as released. Use an existing higher unreleased App Store Connect version when one exists; otherwise advance `MARKETING_VERSION` in every build configuration to the next planned release before committing.
1. Read `<version>` from `MARKETING_VERSION` in `apps/ios/Ox.xcodeproj/project.pbxproj`, confirm all build configurations agree, and confirm it is higher than the released App Store Connect version. Use that unreleased version in new commit subjects.
1. Use the commit message template below. Describe the changes and testing performed; include related issues, pull requests, or commits, or write `None` when there are no related references. State when testing was not run and why.

```text
<imperative summary> (iOS <version>)

Changes:
- <what changed and why>

Testing:
- <checks performed and results>

Related:
- <related references or None>
```

## Repository Boundary

1. This repository must build without private repositories or production credentials.
1. Built-in service sources, sanitized replay fixtures, and the generated runtime bundle belong in this repository.
1. Do not add deployment infrastructure, official signing configuration, raw captures, or unsanitized service data.
1. Select external service repositories explicitly with `--repository <path-or-url>`.
1. Repository URLs must not contain credentials.
1. Local provider keys belong in the gitignored `secrets/API_KEYS.json` and must never be printed, logged, committed, or passed through command-line arguments.

## Uncommitted Local State

1. Never force-add ignored local state or unreviewed generated artifacts.
1. Keep credentials, signing material, production-only configuration, user data, and authenticated captures outside the repository.
1. Store environment-specific overrides in ignored local files or the appropriate secret manager, and reconstruct them in CI from managed environment variables.
1. Keep machine-specific state, build products, dependency caches, diagnostics, recordings, traces, and generated reports outside the repository unless they are intentionally reviewed fixtures.
1. When collaborators need an uncommitted file, provide a sanitized example or generator that contains no private values.

## NPM Releases

1. Public npm package source, verification, and Trusted Publishing workflows belong in this repository so provenance resolves to the public source revision.
1. Bootstrap an unregistered package only from an exact `package:check` tarball through an interactive npm session with two-factor authentication.
1. After bootstrap, publish only through `.github/workflows/publish-npm.yml`; never store an npm publication token in this repository or `openox-dev`.
1. For registered packages, never run `npm publish` locally; bump the package version, commit it to `main`, wait for CI, then create the matching release tag.
1. Use the protected `npm-publish` environment and matching `ox-cli-v*`, `service-sdk-v*`, or `services-v*` tags from `main`.

## Build and Test

1. Use `bun run` scripts for repository operations and `ox` for service operations.
1. Create, explore, repair, and verify web services by driving an Ox chat on the user-selected simulator through the built-in `manage-services` workflow.
1. Do not author service behavior directly from Codex or use terminal browser capture as an alternate development path.
1. Use `.agents/skills/promote-web-service` only after Ox has committed a verified Local service and the user explicitly requests promotion into the built-in repository.
1. Build iOS only with `sim`, never `xcodebuild`.
1. Before simulator testing, start one repository server and verify its `/health` endpoint.
1. Each concurrent process must use its own numbered simulator and matching service, repository, and debug ports.
1. Reuse the fixed `ox-qa-1` through `ox-qa-5` simulator pool; do not create additional numbered QA simulators.
1. Rebuild and install after switching worktrees.
1. A green build is not verification; use repository health, build, launch, exercise, fix, and repeat.
1. For iOS and UX behavior, exercise the flow manually with `sim` and preserve screenshots or videos outside the repository.
1. Record simulator settings before changing them for a test, including Dynamic Type, appearance, and accessibility options, and restore their previous values when finished, including after failures. Keep standard text size for ordinary QA runs unless the test explicitly requires another size.
1. Before pushing, run `bun run typecheck` and the smallest relevant tests.
1. After updating an `.xcstrings` catalog, immediately run `bun run check:localizations` and resolve every missing, incomplete, or placeholder-mismatched required translation before committing it.
1. After changing built-in services or their compiler, run `bun run build:services` and commit the resulting `apps/ios/Ox/Resources/OxServices.bundle` changes.
1. Use `ox` for chats, logs, agent replay, and Server IR verification.

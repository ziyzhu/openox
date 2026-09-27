## General Rules

1. The app must remain neutral to LLM provider.
1. When OpenOx functionality uses OAuth, use apps registered as OpenOx.
1. Logs are user-owned on-device diagnostics.
1. Keep enough structured logs to diagnose production issues.
1. Prefer composition and explicit state.
1. Keep the three feature headings and descriptions identical across `README.md`, `apps/ios/Ox/Client/Features/Onboarding/OnboardingView.swift`, and the website at `../openox-dev/web/index.html`; update the onboarding translations when this copy changes.
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

## NPM Releases

1. Public npm package source, verification, and Trusted Publishing workflows belong in this repository so provenance resolves to the public source revision.
1. Bootstrap an unregistered package only from an exact `package:check` tarball through an interactive npm session with two-factor authentication.
1. After bootstrap, publish only through `.github/workflows/publish-npm.yml`; never store an npm publication token in this repository or `openox-dev`.
1. For registered packages, never run `npm publish` locally; bump the package version, commit it to `main`, wait for CI, then create the matching release tag.
1. Use the protected `npm-publish` environment and matching `ox-cli-v*`, `service-sdk-v*`, or `services-v*` tags from `main`.

## Build and Test

1. Use `bun run` scripts for repository operations and `ox` for service operations.
1. Create, explore, repair, and verify web services by driving an Ox chat on the user-selected simulator through the built-in `manage-services` workflow.
1. When delegating service authoring to Ox, actively look for opportunities to improve the authoring harness and fix issues encountered. Turn those findings into reusable improvements to tools, instructions, diagnostics, and verification so future authoring is faster and more reliable.
1. Do not author service behavior directly from Codex or use terminal browser capture as an alternate development path.
1. Build iOS only with `sim`, never `xcodebuild`.
1. Use bundled services for ordinary simulator testing. Start a repository server and verify its `/health` endpoint only when testing repository installation or sync.
1. Each concurrent process must use its own numbered simulator and matching service and debug ports; reserve its repository port when that test uses a repository server.
1. Reuse the fixed `ox-qa-1` through `ox-qa-5` simulator pool; do not allocate QA names beyond that pool.
1. Run the QA simulator pool on an iOS 26 runtime. Check each selected simulator's runtime before testing; if iOS 26 is unavailable, install it before continuing. When replacing a pool device, retain the old simulator under a backup name until the replacement is verified.
1. Rebuild and install after switching worktrees.
1. A green build is not verification; use repository health, build, launch, exercise, fix, and repeat.
1. For iOS and UX behavior, exercise the flow manually with `sim` and preserve screenshots or videos outside the repository.
1. Record simulator settings before changing them for a test, including Dynamic Type, appearance, and accessibility options, and restore their previous values when finished, including after failures. Keep standard text size for ordinary QA runs unless the test explicitly requires another size.
1. Before pushing, run `bun run typecheck` and the smallest relevant tests.
1. After updating an `.xcstrings` catalog, immediately run `bun run check:localizations` and resolve every missing, incomplete, or placeholder-mismatched required translation before committing it.
1. After changing built-in services or their compiler, run `bun run build:services` and commit the resulting `apps/ios/Ox/Resources/OxServices.bundle` changes.
1. Use `ox` for chats, logs, and Server IR verification.

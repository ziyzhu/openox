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
1. Reproduce the issue first before attempting to fix it so that you can verify the fix.
1. Prefer E2E tests instead of unit tests.
1. Use `sim` and `ox` CLI for testing.
1. For each commit, review lines of code and cyclomatic complexity, prefer low.
1. Show screenshots after making UI changes for human to review.

## Commit Rules

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

## iOS Simulator Setup

1. Use the fixed five-simulator pool: `ox-1`, `ox-2`, and `ox-3` run iOS 26; `ox-4` and `ox-5` run iOS 27. Verify with `sim devices` before testing. Keep replaced devices as backups until their replacements are verified.
1. Before using a simulator, check other agents' sessions and recent `sim` activity. Coordinate ownership and choose another device if it is in use. Never interrupt or change another agent's simulator.
1. Each concurrent agent uses its own simulator and matching ports from `tooling/qa-config.ts`. Always pass `--device` explicitly.
1. Start tests with the same website and provider state on all five simulators, using `ox-1` as the baseline. Copy only when both source and target are free; verify website logins, provider credentials, configuration, and default model afterward.
1. Use `bun run sim:bootstrap --help` for state-copy options. It copies cookies/local storage and installs provider API keys; other website data and provider settings require separate setup. See [website state](.agents/skills/storage-migrations/references/storage.md#website-state).
1. Build and exercise iOS flows with `sim`, never `xcodebuild`. Rebuild and install after switching worktrees; keep screenshots and recordings outside the repository.
1. Use bundled services normally. Start a repository server on the matching port and verify `/health` only when testing repository installation or sync.
1. Use standard text size for ordinary QA. Record settings before changing them and restore them afterward, including after failures.

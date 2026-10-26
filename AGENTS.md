## General Rules

1. The app must remain neutral to LLM provider.
1. Logs are user-owned on-device diagnostics.
1. Keep enough structured logs to diagnose production issues.
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
1. When OpenOx functionality uses OAuth, use apps registered as OpenOx.

## App Rules

1. Keep system skills self-contained and free of external links.
1. Keep agent prompts and bundled System skills in `packages/agent`.
1. `README.md`, `apps/ios/Client/Features/Onboarding/OnboardingView.swift`, and the website at `../openox-dev/web/index.html` should be consistent.
1. UX must hold up across supported devices and use equal outer-edge padding.
1. Always require user confirmation before destructive actions.
1. Shared interactive UI components must require stable automation identifiers and apply them to the actual controls.
1. Reference Apple development documentation for iOS changes.
1. For animation, check [Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/).
1. Keep temporary screenshots, recordings, traces, and diagnostics outside the repository.
1. App Store Connect owns listing metadata and media.
1. Hosted service and model-provider icons live only in the `openox-service-assets-prod` S3 bucket.

## Verification Rules

1. Reproduce the issue first before attempting to fix it so that you can verify the fix.
1. Do not add unit tests; prefer E2E tests.
1. Before committing native source or build-configuration changes, build each affected app target; shared changes require both iOS and macOS builds. Portable checks do not replace native compilation. If a required build cannot run, report the blocker and obtain approval before committing.
1. For each commit, review lines of code and cyclomatic complexity.
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

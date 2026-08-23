## General Rules

1. The app must remain neutral to LLM provider.
1. Logs are user-owned on-device diagnostics.
1. User data is allowed in logs; credentials and reusable secrets are not.
1. Keep enough structured logs to diagnose production issues.
1. Prefer composition, explicit state, and small changes.
1. Keep persisted-storage migration and legacy-format handling in `ios/ios/Storage/ProfileMigration.swift`.
1. Do not modify the service manifest schema without maintainer approval.
1. UX must hold up across supported devices and use equal outer-edge padding.
1. Reference Apple development documentation for iOS changes.
1. Keep temporary screenshots, recordings, traces, and diagnostics outside the repository.

## Repository Boundary

1. This repository must build without private repositories or production credentials.
1. Do not add deployment infrastructure, official signing configuration, private service source, HAR captures, or production service bundles.
1. Select service repositories explicitly with `--repository <path-or-url>`.
1. Repository URLs must not contain credentials.
1. Local provider keys belong in the gitignored `secrets/API_KEYS.json` and must never be printed, logged, committed, or passed through command-line arguments.

## Uncommitted Local State

1. Never force-add ignored local state or generated artifacts.
1. `ios/Local.xcconfig` contains the active Apple team and app identifiers. Create development values with `bun run setup:ios`; official values remain outside this repository and Xcode Cloud writes the file from workflow environment variables through `ios/ci_scripts/ci_post_clone.sh`.
1. `.env`, `.env.*`, and `secrets/API_KEYS.json` contain local configuration or provider credentials and must remain local or in the appropriate secret manager.
1. `docs/SIMULATOR_BOOTSTRAP.local.json` contains machine-specific simulator bootstrap inputs and must remain local.
1. HAR, mitmproxy, browser, simulator, trace, recording, result-bundle, and diagnostic artifacts may contain user data or credentials. Keep them outside the repository even when they reproduce a bug.
1. Build products, dependency caches, derived data, user-specific Xcode state, and generated reports remain ignored and reproducible.
1. Never replace the tracked public service bundle with a private production bundle. Assemble production services only in a disposable or internal checkout.

## Layout

1. `ios/` contains the iOS app and Share Extension.
1. `ox-cli/` contains the Bun service CLI.
1. `dev/` contains the debugger SPA for a running debug build.
1. `tests/llm/` contains real-model evaluation and benchmarks.
1. `tests/services/` contains simulator service replay tooling.
1. `.agents/skills/` contains repository development skills.

## Build and Test

1. Use `bun run` scripts for repository operations and `ox` for service operations.
1. Build iOS only with `sim`, never `xcodebuild`.
1. Before simulator testing, start one repository server and verify its `/health` endpoint.
1. Each concurrent process must use its own numbered simulator and matching service, repository, and debug ports.
1. Rebuild and install after switching worktrees.
1. A green build is not verification; use repository health, build, launch, exercise, fix, and repeat.
1. For iOS and UX behavior, exercise the flow manually with `sim` and preserve screenshots or videos outside the repository.
1. Before pushing, run `bun run typecheck` and the smallest relevant tests.
1. Use `bun run debug` for chats, logs, agent replay, and Server IR verification.

## Documentation

1. `DESIGN.md` defines the brand and visual language.
1. `docs/SECURITY.md` defines the credential-firewall threat model.
1. `docs/STORAGE.md` defines persisted storage and must be updated after persistence changes.
1. `docs/SERVICE_REPOSITORIES.md` defines repository-backed services.

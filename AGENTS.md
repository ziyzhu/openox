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

## Layout

1. `ios/` contains the iOS app and Share Extension.
1. `ox-cli/` contains the Bun service CLI.
1. `service-sdk/` contains reusable service contracts, validation, helpers, and replay tooling published as `@openox/service-sdk`.
1. `services/` contains official built-in service sources and the generated repository package published as `@openox/services`.
1. `examples/service-repository/` is a standalone remote service repository example.
1. `dev/` contains the debugger SPA for a running debug build.
1. `ios/tests/llm/` contains real-model evaluation and benchmarks for the iOS agent.
1. `services/tests/` contains simulator service replay tooling.
1. `.agents/skills/` contains repository development skills.

## npm Releases

1. Public npm package source, verification, and Trusted Publishing workflows belong in this repository so provenance resolves to the public source revision.
1. Bootstrap an unregistered package only from an exact `package:check` tarball through an interactive npm session with two-factor authentication.
1. After bootstrap, publish only through `.github/workflows/publish-npm.yml`; never store an npm publication token in this repository or `openox-dev`.
1. Use the protected `npm-publish` environment and matching `ox-cli-v*`, `service-sdk-v*`, or `services-v*` tags from `main`.

## Build and Test

1. Use `bun run` scripts for repository operations and `ox` for service operations.
1. Build iOS only with `sim`, never `xcodebuild`.
1. Before simulator testing, start one repository server and verify its `/health` endpoint.
1. Each concurrent process must use its own numbered simulator and matching service, repository, and debug ports.
1. Rebuild and install after switching worktrees.
1. A green build is not verification; use repository health, build, launch, exercise, fix, and repeat.
1. For iOS and UX behavior, exercise the flow manually with `sim` and preserve screenshots or videos outside the repository.
1. Before pushing, run `bun run typecheck` and the smallest relevant tests.
1. After changing built-in services or their compiler, run `bun run build:services` and commit the resulting `ios/ios/OxServices.bundle` changes.
1. Use `bun run debug` for chats, logs, agent replay, and Server IR verification.

## Documentation

1. `DESIGN.md` defines the brand and visual language.
1. `docs/SECURITY.md` defines the credential-firewall threat model.
1. `docs/STORAGE.md` defines persisted storage and must be updated after persistence changes.
1. `docs/SERVICE_REPOSITORIES.md` defines repository-backed services.

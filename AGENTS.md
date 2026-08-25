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

## npm Releases

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
1. Rebuild and install after switching worktrees.
1. A green build is not verification; use repository health, build, launch, exercise, fix, and repeat.
1. For iOS and UX behavior, exercise the flow manually with `sim` and preserve screenshots or videos outside the repository.
1. Before pushing, run `bun run typecheck` and the smallest relevant tests.
1. After changing built-in services or their compiler, run `bun run build:services` and commit the resulting `ios/ios/OxServices.bundle` changes.
1. Use `ox` for chats, logs, agent replay, and Server IR verification.
1. Use `bun run test:chat-projection` to replay the committed projection fixtures through a running DEBUG app; pass `--update` only to accept a reviewed projection change.

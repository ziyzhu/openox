---
name: release
description: Prepare and verify OpenOx npm and standalone CLI releases, inspect package artifacts, and invoke the authorized publication workflow. Use for package release work; App Store release operations use asc-cli and repository commit/version rules remain in AGENTS.md.
---

# Release

Publication requires explicit user authorization. Never publish as a verification
step or invoke this skill's publisher from ordinary CI.

## Prepare

Follow repository `AGENTS.md` for commit/version requirements. Package metadata
and package-owned build/check scripts remain the sources of truth. Preserve
unrelated changes. Update the selected package's `package.json` version on `main`.

| Package | Directory | Release tag |
| --- | --- | --- |
| `@openox/cli` | `apps/cli` | `ox-cli-v<version>` |
| `@openox/protocol` | `packages/protocol` | `protocol-v<version>` |
| `@openox/services` | `packages/services` | `services-v<version>` |

Publish the protocol version required by services before publishing services.
Services checks install local protocol and services tarballs together, so
verification requires no prior publication. Run `bun run build:services` from
the repository root before checking the services package.

Run `bun run ci`; CLI releases also require the four-platform standalone checks
in `.github/workflows/cli-standalone.yml`. Each package's `package-check.ts` creates
and verifies its tarball. Keep release artifacts outside the repository.

## Publish

The authorized `.github/workflows/publish-npm.yml` workflow owns publication and
CLI GitHub Release delivery. It validates release tags, repository ancestry, and
artifacts before invoking `.agents/skills/release/scripts/npm-publish.ts` with an
explicit package and verified tarball. Tags must match the package version and
point to a commit on `main`. Do not create or push release tags without authorization.

First npm releases require an authorized interactive publish of the verified
tarball with two-factor authentication. Subsequent releases use npm Trusted
Publishing through the workflow's `npm-publish` environment. CLI tags require
all four standalone platforms to pass before npm publication; after publication,
the workflow uploads archives, `SHA256SUMS`, and `install.sh` to a CLI-specific
GitHub Release.

The publisher validates package name, version, archive name, and npm integrity.
An already-published matching version is a no-op; different contents fail closed.
Its `--dry-run` still queries npm and exercises publication validation, so it is
not an offline test. Do not run it merely to verify a tooling reorganization.

Report the package/version, artifact checks, publication result, and unperformed
steps. Never expose signing keys, npm tokens, or reusable credentials.

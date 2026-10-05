---
name: release
description: Prepare and verify OpenOx npm and standalone CLI releases, inspect package artifacts, and invoke the authorized publication workflow. Use for package release work; App Store release operations use asc-cli and repository commit/version rules remain in AGENTS.md.
---

# Release

Publication requires explicit user authorization. Never publish as a verification
step or invoke this skill's publisher from ordinary CI.

## Prepare

Follow repository `AGENTS.md` for commit/version requirements. Package metadata
and package-owned build/check scripts remain the sources of truth; read the
selected package's README before release work. Preserve unrelated changes.

Run `bun run ci`; CLI releases also require the four-platform standalone checks
in `.github/workflows/cli-standalone.yml`. Each package's `package-check.ts` creates
and verifies its tarball. Keep release artifacts outside the repository.

## Publish

The authorized `.github/workflows/publish-npm.yml` workflow owns publication and
CLI GitHub Release delivery. It validates release tags, repository ancestry, and
artifacts before invoking `scripts/npm-publish.ts` with an explicit package and
verified tarball. Do not create or push release tags without authorization.

The publisher validates package name, version, archive name, and npm integrity.
An already-published matching version is a no-op; different contents fail closed.
Its `--dry-run` still queries npm and exercises publication validation, so it is
not an offline test. Do not run it merely to verify a tooling reorganization.

Report the package/version, artifact checks, publication result, and unperformed
steps. Never expose signing keys, npm tokens, or reusable credentials.

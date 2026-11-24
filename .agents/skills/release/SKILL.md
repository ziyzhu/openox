---
name: release
description: Prepare and verify OpenOx iOS App Store, npm, and standalone CLI releases, and design or verify persisted-storage changes during development. Use for storage migrations and before/after compatibility templates, App Store metadata and manual review handoff, package checks, and authorized publication. App Store operations use asc-cli; commit/version rules remain in AGENTS.md.
---

# Release

Work on `main`. Before preparing a release, inspect `git status` and update with `git pull --ff-only`. Preserve local work; stop if the pull cannot fast-forward. Never publish as a verification step. Website and infrastructure deployment remain in `openox-dev`.

## Storage compatibility

For persisted-storage changes, follow the test-owned [compatibility procedure](../test/references/storage-compatibility.md) and update the [storage map](../test/references/storage.md) as needed. Before release, require actual predecessor-written data, successful upgrade and normal writes, and a stable second launch. Downgrade testing is opt-in and not a release gate; report known limitations.

## App Store releases

Use the installed `asc-cli` skill for App Store Connect and check `asc auth status`. The app ID is `6802224502`. Follow the [App Store release flow](references/release-flow.md) for provenance, listing metadata, release notes, and staging. Keep private artifacts and credentials outside Git.

Start requested App Store release preparation by creating or reusing a **draft without attaching a build**. A released baseline, clean working tree, and finished notes are not prerequisites for creating the draft. Build/upload and attachment are later, separately requested steps. Do not submit App Review or release the app; the operator does both manually.

For TestFlight-only distribution or upload maintenance, see [iOS CI upload and announcement](references/ios-ci.md). CI assigns builds to `gamma` but does not submit Beta App Review. Do not upload just to verify a workflow change.

## Prepare packages

Update the selected package’s `package.json` on `main`. Package metadata and package-owned checks are the sources of truth.

| Package | Directory | Release tag |
| --- | --- | --- |
| `@openox/cli` | `apps/cli` | `ox-cli-v<version>` |
| `@openox/protocol` | `packages/protocol` | `protocol-v<version>` |
| `@openox/services` | `packages/services` | `services-v<version>` |

Run `bun run ci` and the relevant package-owned `package-check.ts`. Run `bun run build:services` before checking the services package; its checks install local protocol and services tarballs together, so verification needs no prior publication. CLI releases also require the four-platform standalone checks in `.github/workflows/cli.yml`. Keep release artifacts outside Git.

## Publish packages

Publication requires explicit authorization; do not create or push release tags without permission. Publish the protocol version required by services first. The authorized `.github/workflows/npm-release.yml` workflow validates package tags, main ancestry, and artifacts before invoking `scripts/npm-publish.ts` with an explicit package and verified tarball. CLI tags require all four standalone platforms to pass; the workflow publishes archives, `SHA256SUMS`, and `install.sh` to a CLI GitHub Release after npm publication.

First npm releases require authorized interactive publication of the verified tarball with two-factor authentication. Later releases use Trusted Publishing through the `npm-publish` environment. The publisher checks package name, version, archive name, and integrity; an identical published version is a no-op and different contents fail closed. `--dry-run` still queries npm and exercises publication validation; it is not an offline test.

Report package/version, artifact checks, publication result, and unperformed steps. Never expose signing keys, npm tokens, or reusable credentials.

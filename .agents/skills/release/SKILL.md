---
name: release
description: Prepare and verify OpenOx iOS App Store, npm, and standalone CLI releases, and design or verify persisted-storage changes during development. Use for storage migrations and before/after compatibility templates, App Store metadata and manual review handoff, package checks, and authorized publication. App Store operations use asc-cli; commit/version rules remain in AGENTS.md.
---

# Release

Run from the selected OpenOx checkout on `main` and follow its `AGENTS.md`.
Choose the storage compatibility, App Store, or package workflow below. A requested
App Store release authorizes preparation, build/upload, release-note translation,
application of the approved English promotional text, and staging within the
requested scope without additional approval prompts.
App Review submission and final release are manual. Package publication requires
explicit user authorization. Never publish as a verification step or invoke this
skill's publisher from ordinary CI.
Website and infrastructure deployment remain in `openox-dev`.

## Storage compatibility

For every persisted-storage change, including development work outside a release,
follow [references/storage-compatibility.md](references/storage-compatibility.md)
and update the canonical [storage map](references/storage.md) when affected.
Require before/after device templates backed by actual build-written snapshots;
verify newer readers with older data and second-launch stability. Downgrade
compatibility, older-reader testing, and downgrade approval are not release gates.
Test downgrades only when explicitly requested; report known limitations without
blocking the release.
`StorageMigrator` coordinates startup and recovery; scoped Profile, application-storage, credential, and repository migrators own compatibility transforms.

## App Store releases

Use the installed `asc-cli` skill for App Store Connect operations and
[demo](../demo/SKILL.md) for requested screenshots or video capture. The app ID
is `6802224502`. Follow [references/release-flow.md](references/release-flow.md)
for inspection, release notes, staging, and manual review handoff.
This workflow is not for TestFlight-only distribution. Start with
`bun .agents/skills/release/scripts/ios-inspect.ts --help`, then follow the
inspection step in the release flow. The script is read-only; its report is
evidence, not proof of submission readiness.

App Store Connect owns current listing metadata, screenshots, and previews.
Read its live state during a release; do not keep local metadata copies, media
libraries, or inventory manifests in either repository. Keep drafts, captures,
downloads, validation output, and CLI input files in a private temporary workspace
outside the repositories. Credentials, signing material, review contacts, and
demo access also stay outside Git.

Current English promotional text, supplied by the operator:

> A self-evolving agent that runs on your phone

Require this exact text in every configured English locale of the intended
version. During release preparation, set it when missing or different, then read
it back; reporting drift alone is insufficient. A release request authorizes
applying this approved copy, not inventing replacement copy. Preserve non-English
promotional text unless a change is requested. Do not automatically translate the
tagline or use it as release notes.
For app updates, require saved, nonempty **What's New in This Version** text in
every configured locale, including `zh-Hans`; English text alone is insufficient.
Review translations before staging and verify all locales afterward. Preserve
other metadata and media unless changes are requested.

## Prepare packages

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

## Publish packages

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

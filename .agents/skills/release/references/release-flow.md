# App Store release flow

## Create the draft

1. Read the intended version from `apps/ios/project.yml` and inspect its live App Store Connect state. Reuse an existing draft; otherwise create the version for app `6802224502` with release type `MANUAL`, after checking installed CLI help.
2. Read back the version and confirm its draft state and that no build is attached. Do not select an uploaded build, upload a new one, or attach a build during draft preparation. A clean working tree, verified released-source baseline, and completed release notes are not prerequisites for creating the draft.
3. For a draft-only request, stop here and report the version, state, and absence of a selected build. Leave metadata and media unchanged. Continue with metadata preparation or build/staging only within the requested scope.

## Inspect

```sh
bun .agents/skills/release/scripts/ios-inspect.ts --version <version>
```

1. Use `--help` for options. Missing baseline, build selection, or release notes are later-step blockers, not draft-creation blockers. Supply `--since <verified-released-commit>` before deriving release notes; supply `--build-id <asc-build-id>` only for a later requested build/staging step. Resolve the report's blockers before the affected build/upload or staging step; the in-app What's New blockers must be resolved before archiving, then rerun inspection. Released-baseline metadata is not staged metadata. Offline reports allow only provisional drafts. Keep reports and release working files in a private temporary workspace outside Git.

## Resolve the released source

Before deriving release notes or asking the operator for a baseline, use the
installed `asc` CLI to trace the last released iOS version to its source commit.
Check each subcommand's `--help` before use.

1. Run `asc versions list --app 6802224502 --platform IOS --include build --paginate`. Identify the latest released version, not the newest draft or TestFlight upload, and record its attached build ID. Use `asc builds info --build-id <released-build-id>` to read its build number and marketing version.
2. Run `asc xcode-cloud workflows --app 6802224502 --paginate`, then `asc xcode-cloud build-runs --workflow-id <workflow-id> --sort=-number --limit 25`. Follow pagination and inspect other app workflows when needed. A matching run number or timestamp is only a candidate, not proof.
3. Run `asc xcode-cloud build-runs builds --run-id <candidate-run-id> --paginate` and require its returned builds to contain the exact released build ID. Read the run's `sourceCommit.commitSha` from the run listing or `asc xcode-cloud build-runs view --id <candidate-run-id>`. Do not substitute the latest successful run or infer a commit from a version bump, release-note commit, or upload date.
4. Confirm the SHA exists locally and is an ancestor of the intended source with `git cat-file -e <sha>^{commit}` and `git merge-base --is-ancestor <sha> HEAD`. Save the version/build/run/SHA evidence in the private temporary workspace, then pass that SHA as `--since` to release inspection. This ASC-verified chain establishes the baseline without operator confirmation.
5. Ask the operator only if ASC provenance is unavailable, missing, ambiguous, or inconsistent, or the released commit is not an ancestor of the intended source. Report what was checked; never guess the baseline. An unavailable baseline blocks release-note derivation, not draft creation.

## What's New in This Version

1. Draft the App Store Connect `whatsNew` field from actual user-visible changes since the last released version. Do not include unshipped work, internal implementation details, or screenshot-only fixtures as shipped features.
2. Use the report's locale inventory and existing notes; if it contains only released-baseline metadata, refresh inspection after the intended version exists. Write concise, release-specific notes for every configured locale, including `zh-Hans` and locales with copied metadata. Do not substitute the promotional tagline, silently carry forward old notes, or remove a locale to bypass validation.
3. Translate the release notes consistently without inventing additional features and review the complete text for each locale before staging. Do not add or remove locales without an explicit request.
4. Write the notes as `• ` bullets and add the same release to the top of `WhatsNew.releases` in `apps/ios/Client/Features/WhatsNew/WhatsNewReleases.swift`: one item per bullet, using the English bullet text as the key and its `zh-Hans` translation as a manual entry in `apps/shared/Resources/Localizations/Localizable.xcstrings`. Users updating from earlier versions see one numbered page per skipped release, newest first, and every shipped release stays listed in Settings > What's New. Keep the in-app entry and the App Store text identical, commit the entry, and rerun inspection; it blocks when the entry, its position, or a translation is missing, and when saved App Store notes differ from it.
5. Validate the text against current Apple field requirements and available offline CLI validation. If a CLI metadata layout is required, populate it from the current remote state plus the intended changes in the temporary workspace; verify every intended locale and field is covered.

## Build

1. Confirm the selected source revision is reviewed and the remote build came from it; the script cannot prove either. For an official build/upload within the requested release, use `xcodebuild` with the reviewed project, scheme, signing configuration, and explicit output paths outside Git. Inspect native help; do not invent existing archive paths. Make version changes in `apps/ios/project.yml`, regenerate the Xcode project, and verify matching app and Share Extension versions in the archive. Complete storage compatibility checks when applicable. These release checks are not required for ordinary commits.

## Stage

1. Record the exact version/build, What's New text, approved English promotional text, and intended remote changes for the handoff. Set missing or differing English promotional text to the operator-approved copy in SKILL.md as part of release preparation. Preserve non-English promotional text, descriptions, URLs, screenshots, and previews unless a separate change was requested.
2. Only when build attachment is requested, select the exact processed build with verified source provenance. Run available dry runs, apply only the intended fields, and attach that build without an additional approval prompt. Otherwise leave the draft without a selected build. Stop at preparation if no processed build or signed IPA from the requested release is available.
3. If media changes are requested, use the demo workflow, current Apple specifications, and synthetic content. Keep assets outside Git, inspect existing remote media, and validate and visually review replacements before applying the requested changes.
4. Wait for build/media processing and run the strongest available readiness validation. Read back What's New for every configured locale, require nonempty text for app updates, compare changed notes with the intended text, rerun inspection with the selected build to confirm the saved notes match the shipped in-app entry, require exact approved promotional text in every configured English locale, and verify the selected build. Confirm unrelated fields and locales are unchanged. A successful write alone does not establish readiness. Report blockers and warnings; do not change privacy, pricing, agreements, or other account state beyond the requested scope.

## Manual submission and release

Stop with the exact version/build, reviewed release notes, validation results, and unresolved manual checks. Never call `asc review submit`, use `asc publish appstore --submit`, or invoke an equivalent submission operation; the operator submits in App Store Connect.

The operator also performs final release of versions pending developer release; do not invoke release operations. Monitor with bounded polling and report only states confirmed by App Store Connect. If a mutation times out, inspect remote state before retrying.

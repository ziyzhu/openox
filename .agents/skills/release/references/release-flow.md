# App Store release flow

## Inspect

```sh
bun .agents/skills/release/scripts/ios-inspect.ts --since <verified-released-commit> --build-id <asc-build-id>
```

1. Supply the verified source commit of the last released iOS build and explicitly select the intended build. Use `--help` for options. Resolve the report's blockers before the affected build/upload or staging step, then rerun inspection. Missing builds or version records allow preparation only; released-baseline metadata is not staged metadata. Offline reports allow only provisional drafts. Keep reports and release working files in a private temporary workspace outside Git.
2. Confirm the selected source revision is reviewed and the remote build came from it; the script cannot prove either. For an official build/upload within the requested release, use `xcodebuild` with the reviewed project, scheme, signing configuration, and explicit output paths outside Git. Inspect native help; do not invent existing archive paths. Make version changes in `apps/ios/project.yml`, regenerate the Xcode project, and verify matching app and Share Extension versions in the archive. Complete storage compatibility checks when applicable. These release checks are not required for ordinary commits.

## What's New in This Version

1. Draft the App Store Connect `whatsNew` field from actual user-visible changes since the last released version. Do not include unshipped work, internal implementation details, or screenshot-only fixtures as shipped features.
2. Use the report's locale inventory and existing notes; if it contains only released-baseline metadata, refresh inspection after the intended version exists. Write concise, release-specific notes for every configured locale, including `zh-Hans` and locales with copied metadata. Do not substitute the promotional tagline, silently carry forward old notes, or remove a locale to bypass validation.
3. Translate the release notes consistently without inventing additional features and review the complete text for each locale before staging. Do not add or remove locales without an explicit request.
4. Validate the text against current Apple field requirements and available offline CLI validation. If a CLI metadata layout is required, populate it from the current remote state plus the intended changes in the temporary workspace; verify every intended locale and field is covered.

## Stage

1. Record the exact version/build, What's New text, and intended remote changes for the handoff. Preserve promotional text, descriptions, URLs, screenshots, and previews unless a separate change was requested. Check the documented promotional text against live state; report drift rather than silently overwriting it.
2. Run available dry runs, apply only the intended fields, and attach the exact processed build without an additional approval prompt. Stop at preparation if no processed build or signed IPA from the requested release is available.
3. If media changes are requested, use the demo workflow, current Apple specifications, and synthetic content. Keep assets outside Git, inspect existing remote media, and validate and visually review replacements before applying the requested changes.
4. Wait for build/media processing and run the strongest available readiness validation. Read back What's New for every configured locale, require nonempty text for app updates, compare changed notes with the intended text, and verify the selected build. Confirm unrelated fields and locales are unchanged. A successful write alone does not establish readiness. Report blockers and warnings; do not change privacy, pricing, agreements, or other account state beyond the requested scope.

## Manual submission and release

Stop with the exact version/build, reviewed release notes, validation results, and unresolved manual checks. Never call `asc review submit`, use `asc publish appstore --submit`, or invoke an equivalent submission operation; the operator submits in App Store Connect.

The operator also performs final release of versions pending developer release; do not invoke release operations. Monitor with bounded polling and report only states confirmed by App Store Connect. If a mutation times out, inspect remote state before retrying.

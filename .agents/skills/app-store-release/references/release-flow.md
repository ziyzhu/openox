# App Store release flow

## Inspect

1. Resolve the selected OpenOx commit, intended iOS version, and exact build. Require all `MARKETING_VERSION` configurations to agree and a clean reviewed revision before an official build or staging. Build with `sim`, not `xcodebuild`; do not invent a build or archive path.
2. Follow the installed `asc-cli` skill and current command help. Use app `6802224502` explicitly, inspect its current versions and processed builds, and read the selected version's localized metadata and media from App Store Connect.
3. Use the last released version and selected source revision to establish the release's change range. Keep any downloads, drafts, CLI metadata layouts, and validation reports in a private temporary workspace, not Git. If working offline, report remote state as unchecked and stop at a provisional draft.

## What's New in This Version

1. Draft the App Store Connect `whatsNew` field from actual user-visible changes since the last released version. Do not include unshipped work, internal implementation details, or screenshot-only fixtures as shipped features.
2. Enumerate every configured version locale from App Store Connect, following pagination, and read its existing notes. For app updates, What's New is required in each locale, including locales whose other metadata was copied from the previous version. English notes do not satisfy `zh-Hans`; report null, empty, or whitespace-only notes as blockers. Write concise release-specific improvements and fixes; do not substitute the promotional tagline, silently carry forward old notes, or remove a locale to bypass validation.
3. Present the complete proposed text for each locale for human review. Translate the approved release notes consistently without inventing additional features. Translations remain draft until approved; do not add or remove locales without an explicit request.
4. Validate the approved text against current Apple field requirements and available offline CLI validation. If a CLI metadata layout is required, populate it from the current remote state plus the approved changes in the temporary workspace; verify every intended locale and field is covered.

## Stage

1. Show the exact version/build, approved What's New text, and proposed remote changes. Preserve promotional text, descriptions, URLs, screenshots, and previews unless a separate change was requested and approved. Check the documented promotional text against live state; report drift rather than silently overwriting it.
2. Run available dry runs and request explicit staging approval. Apply only the approved fields and attach the exact processed build. Stop at preparation if no processed build or separately authorized signed IPA is available.
3. If media changes are requested, use the demo workflow, current Apple specifications, and synthetic content. Keep assets outside Git, inspect existing remote media, validate and visually review replacements, and obtain separate approval before replacing or deleting anything.
4. Wait for build/media processing and run the strongest available readiness validation. Read back What's New for every configured locale, require nonempty text for app updates, compare changed notes with the approved text, and verify the selected build. Confirm unrelated fields and locales are unchanged. A successful write alone does not establish readiness. Report blockers and warnings; do not change privacy, pricing, agreements, or other account state beyond the approved scope.

## Manual submission and release

Stop with the exact version/build, reviewed release notes, validation results, and unresolved manual checks. Never call `asc review submit`, use `asc publish appstore --submit`, or invoke an equivalent submission operation; the operator submits in App Store Connect.

After App Review approval, releasing a version pending developer release requires separate explicit approval. Monitor with bounded polling and report only states confirmed by App Store Connect. If a mutation times out, inspect remote state before retrying.

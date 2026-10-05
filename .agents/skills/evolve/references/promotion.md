# Promote an Ox web service

Treat the committed Local service produced by Ox as the behavioral source of truth. Promotion packages and verifies that implementation; it does not provide a second authoring path.

## Preconditions

Require all of the following before changing built-in service source:

- Ox created or copied the service into Local through `skills/evolve/SKILL.md`.
- Ox explored the live site through `ox.web.browser.*` and followed the current `evolve` planning and approval rules, including its scoped missing-service bootstrap path.
- Ox verified every promoted action and applicable authentication or handoff boundary in iOS.
- The Local service has a verified, saved revision with no unrelated pending Local changes.
- The user explicitly requested promotion into the official built-in repository.

If any precondition is missing, return to Ox on the requested simulator. Do not substitute terminal Chrome, mitmproxy exploration, direct source editing, or inferred endpoint behavior.

When returning work to Ox for authoring or repair, follow the `cli` skill's service-authoring guidance: use observed friction and failures to improve the harness, fix underlying issues, and verify the affected flow through Ox so future authoring is faster and more reliable.

## Export the Local source

Read `service.json`, `actions.js`, Local Git status, and the exact saved Local revision through Ox's debug or service-management APIs. Export from the virtual filesystem into a private temporary directory outside the repository. Do not reconstruct source from chat text or logs.

Compare the exported source with any existing built-in service and report behavioral differences before replacing it. Preserve unrelated built-in changes.

The official source uses the same plain-JavaScript installer format as Local. Copy the exact saved `actions.js` without translation and preserve every behavioral manifest field. Use the verified Local `faviconUrl` as an artwork source, store an audited `favicon.png`, and omit the third-party URL override from the built-in manifest so the build assigns the OpenOx CloudFront asset URL. Deploy the reviewed icon through the existing service-assets workflow with an explicit OpenOx checkout and verify its anonymous hosted response before delivery. Favicons load through URLs only; do not include PNG assets in the generated runtime bundle or add an on-device fallback. The build must reject syntax errors, installers that pass a version, multiple installations, and manifest-registration mismatches. Do not hand-rewrite Ox-authored JavaScript as a second implementation.

An installed app's validator can lag behind the repository compiler. If the exported manifest fails current compilation, return the diagnostic to Ox for repair, verification, and a new saved revision before re-exporting.

## Live verification evidence

Verify the promoted service through Ox on a reserved simulator. Verification may exercise already declared actions, but must not become endpoint exploration or service redesign.

- Ask the user to perform sign-in, challenges, and account selection.
- Require explicit approval before any live mutation.
- Exercise success, empty, terminal pagination, safe error, and authentication behavior where available without inventing data or success.
- Keep screenshots, logs, and authenticated diagnostics in a private temporary directory outside the repository.
- Sanitize identities, account identifiers, user-authored content, cookies, authorization values, CSRF values, and signed URLs before sharing evidence.
- Preserve the authoring app's Local source, credentials, and other data.

The former repository replay command, harness, and committed response fixtures are no longer available. Report live verification boundaries and any behavior that could not safely be exercised.

## Icon

Check that the Local manifest's `faviconUrl` still returns a direct HTTPS PNG or JPEG without redirects, authentication, or cookies, fits the app's 1 MiB download limit, and remains recognizable at 20 px. Fetch the official compact mark with `.agents/skills/evolve/scripts/favicon-128.sh <domain> <verified-favicon-url>` and audit it with `.agents/skills/evolve/scripts/favicon-audit.sh <path-to-favicon.png>`.

Require an official square source that is at least 128×128, remains recognizable at 20 px, has an intentional background in the central safe area, and renders cleanly on light and dark backgrounds. Never upscale, reconstruct brand artwork, or accept a generic substitute.

## Verify and report

Verify the affected actions live through Ox, then:

```bash
bun run build:services
bun run typecheck
```

Verify the generated `apps/ios/Ox/Resources/OxServices.bundle` diff contains only the promoted service and expected index changes. Report the saved Ox Local revision only when technical detail is useful or requested; otherwise report the promoted files, live verification, authentication boundaries, icon evidence, checks run, and any remaining limitation.

Do not commit repository changes unless the user separately requests it.

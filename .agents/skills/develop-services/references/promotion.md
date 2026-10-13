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

When returning work to Ox for authoring or repair, follow the `ox-cli` skill's service-authoring guidance: use observed friction and failures to improve the harness, fix underlying issues, and verify the affected flow through Ox so future authoring is faster and more reliable.

## Export the Local source

Read `service.json`, `actions.js`, Local Git status, and the exact saved Local revision through Ox's debug or service-management APIs. Export from the virtual filesystem into a private temporary directory outside the repository. Do not reconstruct source from conversation text or logs.

Compare the exported source with any existing built-in service and report behavioral differences before replacing it. Preserve unrelated built-in changes.

The official source in `apps/shared/Resources/OxServices.bundle/` uses the same plain-JavaScript installer format as Local. Copy the exact saved `actions.js` without translation and preserve every behavioral manifest field. Use the verified Local `faviconUrl` as an artwork source, upload the audited icon to `https://openox.ai/assets/services/<domain>/favicon.png`, and set the built-in manifest's `faviconUrl` to that URL. Verify its anonymous hosted response before delivery. Favicons load through URLs only; do not include PNG assets in the runtime bundle or add an on-device fallback. The build must reject syntax errors, installers that pass a version, multiple installations, and manifest-registration mismatches. Do not hand-rewrite Ox-authored JavaScript as a second implementation.

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

Reuse the verified Local icon; do not repeat discovery during promotion. If it no longer loads or does not qualify, return to Ox's Choose a favicon workflow for a replacement and a newly verified saved revision.

Fetch and convert that source from a temporary directory with `.agents/skills/develop-services/scripts/favicon-128.sh <domain> <verified-favicon-url>`, then run `.agents/skills/develop-services/scripts/favicon-audit.sh <path-to-favicon.png>` and inspect its 128 px and 20 px light/dark preview. Require an official square raster source at least 128×128 or an official vector source, a recognizable sharp mark, adequate contrast, balanced padding, and no clipped essential artwork. Transparency is acceptable when both previews pass. Never upscale raster artwork, reconstruct a brand mark, or accept a generic substitute. Script success verifies processing, not visual quality.

Upload the reviewed 128×128 PNG to the canonical hosted URL. Fetch that URL anonymously without redirects, confirm a PNG response and bytes matching the reviewed file, then set the built-in `faviconUrl`. Reload and inspect one actual small Ox avatar in both themes using the hosted URL; Local-source evidence alone does not verify the hosted delivery.

## Verify and report

Verify the affected actions live through Ox, then:

```bash
bun run build:services
bun run typecheck
```

Verify the canonical `apps/shared/Resources/OxServices.bundle` diff contains only the promoted service and expected index changes. Report the saved Ox Local revision only when technical detail is useful or requested; otherwise report the promoted files, live verification, authentication boundaries, icon evidence, checks run, and any remaining limitation.

Do not commit repository changes unless the user separately requests it.

---
name: add-web-service
description: Implement or extend an Ox web service from captured evidence — author manifest.json and actions.ts in its Ox Server source directory, reduce and import case-scoped HAR flows, add replay tests, verify browser-backed service behavior, and fetch the domain icon. Use when creating a web service, adding or changing web actions after endpoint exploration, updating web-service behavior, importing fixtures, or obtaining a website's favicon/logo. Use explore-service first when endpoints or live response shapes are unknown or stale.
---

# Add an Ox web service

Work in `services/builtin/web/<domain>/`; the directory and manifest domain
must match. A complete service has `manifest.json`, `actions.ts`,
`replay.ts`, sanitized `actions.har`, and `favicon.png`. Add
`skills/<name>/SKILL.md` only for guidance the action schemas cannot express.

## Workflow

1. Start from an `explore-service` handoff or a user-provided HAR. If endpoints,
   request headers, redirect behavior, or live response shapes are unknown or
   stale, use `explore-service` before editing this service. Never guess them.
2. Inspect the existing service, related implementations, manifest source,
   replay cases, and captured evidence before designing actions.
3. Confirm the handoff covers the action's success, empty, pagination, and safe
   error shapes. Resolve capture gaps through `explore-service` instead of
   widening an implementation around incomplete evidence.
4. Choose authentication and extraction, then define narrow action results and
   schemas from observed shapes. Read [references/actions.md](references/actions.md)
   before authoring or changing `actions.ts`.
5. Read [references/manifest.md](references/manifest.md) before authoring or
   changing `manifest.json`, schemas, copy, or localization.
6. Import sanitized case-scoped flows into `actions.har`, add typed cases to
   `replay.ts`, build, and run fail-closed replay.
7. Fetch the icon and perform live exercise only when replay cannot establish
   behavior. Return to `explore-service` when current drift must be mapped.

## Sanitize and import

Reduce each raw capture from the exploration handoff to the exact requests
needed by one action. Include the base document and the required occurrence
count of each action request; do not carry noisy duplicates, assets, telemetry,
or unrelated exploration routes into fixtures.

Inspect every retained request and response header, cookie, URL/query value,
form/JSON body, redirect, and response body. Remove cookie and authorization
values, CSRF, API keys, reusable secrets, and irrelevant fields. Preserve names
of removed cookies and secret-bearing headers only in `_oxRedactions` with
fixed `[REDACTED]` values. Replace private names, email addresses, phone
numbers, postal addresses, precise locations, account identifiers, and
user-authored content with stable synthetic values of the same shape. Never
print sensitive values. Automated redaction/audit is a backstop, not proof that
a capture is safe.

Preserve an already captured write response; never repeat a live mutation just
to make a fixture. Import one scoped case per action:

```bash
OX_SERVER_SOURCE=services/builtin/web ox --repository <generated-repository> --runtime chrome service test --import <domain>:<actionId> --har /path/to/capture.har --request <METHOD> '<exact-url>'
```

Repeat `--request` for repeated identical requests. The importer derives the
expected result through fail-closed replay, updates `replayCases` in
`replay.ts`, and adds `<action>:<case>`-scoped flows to `actions.har`.

## Implementation essentials

- Keep action state invocation-local and never navigate the main frame.
- Throw on failures; the runtime validates action inputs and outputs.
- Mask credential-grade data in results. Require approval for every mutation.
- Never move money through an action; prepare state and hand final commitment to
  the user through the payment flow.
- Use `services/manifest.ts` as the closed schema source of truth. Do not
  modify the manifest schema without permission.
- Give every action clear consumer-facing copy; keep implementation details out
  of descriptions and fully localize any declared locale.

## Icon and optional skill

From the service directory, run
`../../../../.agents/skills/add-web-service/scripts/favicon-128.sh <domain>` to create
the 128×128 `favicon.png`, then run
`../../../../.agents/skills/add-web-service/scripts/favicon-audit.sh favicon.png`. The
audit enforces the canvas and central-background requirements and writes a
four-part preview: 128 px on light and dark, followed by a 20 px small-size
rendering on light and dark enlarged with nearest-neighbor scaling for
inspection.

Treat the fetched image and a passing audit as candidates, not proof of
quality. The final icon must:

- Use the service's recognizable official compact mark. Prefer an official
  vector, apple-touch icon, or web-manifest icon with a square composition.
- Be sharp at 128 px and remain recognizable at 20 px without relying on small
  text, fine seal detail, or a horizontal wordmark.
- Be centered, fill the frame intentionally, and avoid clipping, edge contact,
  or excessive empty padding.
- Include an intentional official background with enough contrast for the
  mark. Transparent rounded outer corners are acceptable, but the central
  96×96 safe area must be opaque. Never rely on Ox's generated service tint
  to supply missing brand artwork.
- Look correct in all four audit panes. Light or dark halos, matte fringes,
  mismatched corner fills, blur, and disappearing details are failures.

Never upscale a raster source, accept a generic or unrelated mark, reconstruct
brand artwork, use a screenshot or page tile, or accept an icon merely because
its output dimensions and automated audit are valid.

The fetch script rejects raster sources smaller than 128×128 and supports
official SVG sources. It also rejects candidates whose transparency enters the
central safe area so discovery can continue to a source with an intentional
background. If automated discovery fails or selects the wrong brand, find a
better official asset in the site's own HTML, CSS, manifest, static assets, or
raw HAR and rasterize it without enlargement. If no qualifying official asset
exists, stop and report the icon as blocked rather than shipping a blurry,
poorly composed, or misleading substitute.

The audited source file remains at `services/builtin/web/<domain>/favicon.png`.
The Ox Server asset deployment publishes it to
`https://openox.ai/assets/services/<domain>/favicon.png`; generated service
repositories and the iOS app bundle store only that `faviconUrl`, not the image.

Add a service-specific skill only when the agent needs guidance beyond action
schemas. Put it at `skills/<lowercase-hyphen-name>/SKILL.md`; match the directory
and frontmatter name and keep its guidance self-contained.

## Verify

```bash
bun run build:services
bun services/export.ts --output <new-temporary-directory>/repository
bun run test:services -- <domain> --repository <new-temporary-directory>/repository --device <claimed-ox-qa-N>
.agents/skills/add-web-service/scripts/favicon-audit.sh services/builtin/web/<domain>/favicon.png
```

Replay must pass through the authoritative iOS harness without internet
fallback. Replayed writes use captured responses and have no external side
effects. Manually inspect
final `actions.har` for private data even after the audit passes.

Ask the user to sign in before live authenticated verification. Never perform a
live write without explicit approval:

```bash
ox service invoke <domain>:<actionId> --args '{"query":"..."}'
```

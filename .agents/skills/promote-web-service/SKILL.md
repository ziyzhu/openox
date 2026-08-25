---
name: promote-web-service
description: Promote an Ox-authored, verified Local web service into the official built-in service repository, add sanitized replay coverage, audit its public icon, rebuild the generated bundle, and run release checks. Use only after service exploration, action design, implementation, and live verification were completed inside Ox through the built-in manage-services workflow. Do not use to create, explore, repair, or redesign a service.
---

# Promote an Ox web service

Treat the committed Local service produced by Ox as the behavioral source of truth. Promotion packages and verifies that implementation; it does not provide a second authoring path.

## Preconditions

Require all of the following before changing built-in service source:

- Ox created or copied the service into Local through `skills/system:manage-services/SKILL.md`.
- Ox explored the live site through `ios:browser`, presented the action plan, and received separate confirmation before authoring.
- Ox verified every promoted action and applicable authentication or handoff boundary in iOS.
- The Local service has a user-approved Git commit with no unrelated pending Local changes.
- The user explicitly requested promotion into the official built-in repository.

If any precondition is missing, return to Ox on the requested simulator. Do not substitute terminal Chrome, mitmproxy exploration, direct source editing, or inferred endpoint behavior.

## Export the Local source

Read `manifest.json`, `actions.js`, Local Git status, and the exact Local commit through Ox's debug or service-management APIs. Export from the virtual filesystem into a private temporary directory outside the repository. Do not reconstruct source from chat text or logs.

Compare the exported source with any existing built-in service and report behavioral differences before replacing it. Preserve unrelated built-in changes.

The official source currently uses compiled Server IR. Use an existing lossless importer when available. If the repository cannot ingest Local `manifest.json` and `actions.js` without translating or redesigning the implementation, stop and identify the missing generic promotion tooling. Do not hand-rewrite Ox-authored JavaScript as a second implementation.

## Replay evidence

Replay verification may exercise already declared actions, but must not become endpoint exploration or service redesign.

- Capture only the requests needed by the committed action contracts.
- Ask the user to perform sign-in, challenges, and account selection.
- Require explicit approval before any live mutation.
- Keep raw authenticated captures in a private temporary directory outside the repository.
- Sanitize cookies, authorization values, CSRF values, signed URLs, identities, account identifiers, and user-authored content before import.
- Retain success, empty, terminal pagination, safe error, and authentication cases that apply to the committed contracts.
- Inspect every retained request and response after automated redaction.

Import each sanitized case through the current replay tooling and run it fail-closed through the authoritative iOS harness.

## Icon

Use the Local manifest's verified public `faviconUrl` as evidence. Fetch the official compact mark with `scripts/favicon-128.sh <domain>` and audit it with `scripts/favicon-audit.sh <path-to-favicon.png>`.

Require an official square source that is at least 128×128, remains recognizable at 20 px, has an intentional background in the central safe area, and renders cleanly on light and dark backgrounds. Never upscale, reconstruct brand artwork, or accept a generic substitute.

## Verify and report

Run the smallest relevant replay cases, then:

```bash
bun run build:services
bun run typecheck
```

Verify the generated `ios/ios/OxServices.bundle` diff contains only the promoted service and expected index changes. Report the Ox Local commit, promoted files, replay cases, authentication boundaries, icon evidence, checks run, and any remaining limitation.

Do not commit repository changes unless the user separately requests it.

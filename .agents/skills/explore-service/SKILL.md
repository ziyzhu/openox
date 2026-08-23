---
name: explore-service
description: Explore a website before implementing or repairing an Ox service — inspect existing actions, use Ox's headed Chrome session and mitmproxy to capture authorized traffic, drive read-only same-origin discovery with service eval, inventory endpoints and response shapes, diagnose page-generated, signed, redirected, or CORS-constrained requests, and produce a sanitized implementation handoff. Use when endpoints are unknown, HAR evidence is missing or stale, pagination/auth/error shapes need discovery, or a live service must be mapped before editing manifest.json or actions.ts.
---

# Explore an Ox service

Explore first and implement later. Produce evidence that `add-web-service` can turn
into narrow actions and replay fixtures without guessing endpoints.

## Workflow

1. Inspect any existing service before opening the site:

   ```bash
   ox --repository <generated-repository> service inspect -s <domain>
   ox --repository <generated-repository> service actions -s <domain> --json
   ```

   Read its action code and existing replay cases when they reveal observed
   headers, extraction modes, pagination conventions, or known limitations.
2. Set the exploration boundary. Default to GET and HEAD. A write requires the
   user's explicit authorization for that exact mutation; do not infer it from
   a broad request to inspect or capture a service.
3. Establish the authorized browser session with `ox --runtime chrome`.
   Check auth through an existing auth-state action when available. Use
   `service auth` for a user-operated sign-in handoff; never enter credentials
   or solve challenges.
4. Capture into a private temporary directory with the installed `mitmdump`:
   bind to `127.0.0.1`, use a unique port and `confdir`, disable QUIC and
   background networking in the isolated browser, stream each round to a new
   native `.mitm` file, and keep upstream verification enabled. Tell the user
   when recording becomes active.
5. Exercise success, empty, pagination, and safe error states. Capture both the
   ordinary page response and the site's application-native data request when
   they differ.
6. Close the capture browser, stop mitmproxy with `SIGINT`, verify the native
   flow file, and export an immutable raw HAR offline. Never append to or
   overwrite an earlier round.
7. Reduce the evidence to service traffic. Ignore assets and telemetry, then
   inventory hosts, methods, paths, statuses, MIME types, occurrences,
   redirects, response shapes, pagination, and error forms.
8. Produce the handoff described below. Do not edit `manifest.json`,
   `actions.ts`, or replay fixtures unless the user also asks for
   implementation.

## Use Ox Chrome safely

The Ox-owned Chrome profile is isolated from the user's normal Chrome. If
it already holds the required session but cannot be relaunched behind the
proxy, make a private temporary clone, exclude its lock and Ox debug-port
files, and launch only the clone through mitmproxy. The clone contains reusable
session credentials: keep it outside the repository and treat it like the raw
capture. Leave the original profile and its running browser untouched.

Do not use `service test --record` for endpoint exploration: it requires an
already declared action and writes a replay case. Inspect
`ox-cli/chrome/browser.ts` and the Chrome recording path in
`ox-cli/service-test.ts`, launch the temporary profile with their current
proxy, QUIC, background-networking, and certificate flags, then point
subsequent `service open`, `service status`, and `service eval` commands at that
profile with `OX_CHROME_PROFILE`.

`ox service eval` is sufficient for known same-origin read exploration. Use
explicit `fetch` calls with `method: "GET"` and `credentials: "include"`, and
return only structural summaries such as status, final URL, MIME type, byte
length, field names, array lengths, and pagination indicators. Do not return
response bodies or private field values merely to inspect a shape.

Do not click unknown elements, submit forms, or execute page controls through
`service eval`. When an interaction cannot be established as read-only, ask
the user to drive it while recording and wait for an explicit “done.”

## Capture implementation-ready requests

- Follow pagination beyond the first visible page. Record the actual cursor,
  page number, `has_more`, or next-link contract and an empty terminal page.
- Do not assume normal navigation and action fetches return the same shape.
  When existing code or captured page traffic uses special headers, repeat the
  request with those exact observed headers. Never invent verification,
  signature, or anti-bot headers.
- Record status changes caused by request mode. A route returning JSON to the
  app may return HTML, 404, or 406 with another header set; that is part of the
  contract.
- Prefer structured JSON when the page exposes it. When a JSON field contains
  an HTML fragment, inventory both the JSON envelope and the fragment's stable
  selectors or links.
- Distinguish network success from action readability. A proxy may capture a
  cross-origin redirect and a 200 destination while page JavaScript receives
  `TypeError: Failed to fetch` because of CSP or CORS. Record both facts.
- Treat signed redirect query strings and temporary download URLs as
  credential-grade data. Preserve only their redacted shape and do not design
  fixtures around expiring signatures.

If the HAR does not explain a page-generated or signed request, read
[references/request-diagnosis.md](references/request-diagnosis.md).

## Protect the capture

- Treat native flows, HARs, temporary profiles, and mitmproxy CAs as sensitive.
  Keep raw rounds outside version control and never print cookies,
  authorization headers, signed queries, CSRF values, or private response
  bodies.
- Before sharing or importing anything, create a separate reduced derivative.
  Remove secret values from headers, cookies, queries, forms, JSON, redirects,
  and WebSocket messages. Replace private identities, account identifiers, and
  user-authored content with stable synthetic values of the same shape.
- Verify that every retained target request used an authorized method. Separate
  unrelated browser telemetry from target service traffic; unexpected target
  writes are a capture failure, not harmless noise.
- Keep temporary rounds until the user confirms exploration is finished or the
  implementation handoff is accepted. Then remove the exact temporary capture
  directory and explain that the raw credential-bearing material is gone.

## Handoff to add-web-service

Provide:

- The target domain, explored use cases, auth state, browser/profile strategy,
  mitmproxy version, proxy mode, capture filter, and numbered raw rounds.
- A safe endpoint inventory with method, host, path shape, status, MIME type,
  occurrence count, redirect behavior, and whether action JavaScript can read
  the result.
- Success, empty, pagination, and error response shapes using field names and
  types rather than private values.
- The exact candidate request sequence for each proposed action and which
  flows a case-scoped fixture must retain.
- Known blockers such as CORS, CSP, expiring signed URLs, bot gates, incomplete
  pagination, or user interaction still required.
- The private raw-capture location and any sanitized derivative, clearly
  labeled. Never commit or present the raw capture as sanitized.

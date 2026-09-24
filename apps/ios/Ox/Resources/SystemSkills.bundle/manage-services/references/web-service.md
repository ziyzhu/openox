# Web Service

Deliver a useful Local service from live website evidence and report its verified boundaries. Work inside Ox with awaited `ox.*` calls, `ox.web.browser`, the virtual filesystem, and Local Git. Author plain JavaScript against the service version declared in `service.json`; the iOS workflow has no shell, build, TypeScript, HAR, or replay step.

## Missing-service bootstrap

Use when successful `ox.service.find` finds no suitable service for a website task, not when discovery fails. General public-information questions need no service.

1. Inspect the needed `ox.web.browser.*` contracts. Fulfill the original request while collecting evidence for only the needed actions and handoffs.
2. Answer reads as soon as evidence supports them; do not wait for creation or Save. For mutations, prefer observation followed by one approved service invocation; Browser may execute instead when practical. Preserve approval and human-handoff boundaries either way.
3. Build from the observed flow. The original request establishes minimal action scope, so skip separate plan confirmation unless a decision or expanded scope needs it. First attachment, live-mutation approval, and Save confirmation still apply.
4. Validate and verify the service using the workflow below. Browser success alone does not verify a handler. If creation or Save is declined or blocked, continue authorized Browser fulfillment and report the persistence limitation.

Never repeat a completed mutation for evidence or testing. Track pending, completed, and uncertain effects; inspect resulting state before retrying uncertain effects, and ask if uncertainty remains. Disclose unexecuted handlers as partially verified at Save and completion.

```text
services/web/<domain>/
├── service.json
└── actions.js
```

## 1. Discover the service

1. Inspect the exact `ox.web.browser.*` contracts the exploration expects to use, including interaction, capture, page JavaScript, document-start injection, and cleanup functions.
2. Navigate to the requested URL and wait for the top-level URL to settle.
3. Identify the coherent product surface and the hosts needed by its actions.
4. Search with `ox.service.find` for the requested host, final host, and plausible parent-domain candidates.
5. Choose a bare lowercase service domain that equals or is a parent suffix of every base URL host. Keep distinct products or account surfaces as separate services.
6. When the service already exists, inspect its manifest and source read-only. Do not copy or edit it yet.

Defer creation or copying until evidence supports the established action scope. Deliberate authoring also requires plan confirmation below. Discovery alone must not leave a Local draft.

Use the recognizable product name, such as `Outlook`, rather than a hostname-derived label. Include a domain suffix only when it is part of the official name or distinguishes otherwise ambiguous products.

Choose the lightest stable top-level `baseUrl` on the service domain or a subdomain that preserves the cookies, storage, page globals, and runtime behavior the actions need. Prefer an inert same-origin resource that returns a displayable `200` without authentication-dependent redirects when the actions need only cookies, storage, and same-origin requests. Stable HTML, text, `robots.txt`, or favicon resources are candidates only after Browser verifies the final URL, dispatcher injection, and required same-origin requests while signed in and signed out. Never use a cross-origin CDN asset as an execution base. Keep actions that depend on application DOM or page globals on the actual application route through an action-specific `baseUrl`. For example, `xiaohongshu.com` can use a page on `www.xiaohongshu.com`, while a distinct creator surface can remain its own service.

Consult one existing service only when it clarifies the implementation. Choose the closest observed pattern:

- `news.ycombinator.com`: public HTML, pagination, authentication, mutation.
- `github.com`: broad public and signed-in reads.
- `xiaohongshu.com`: signed resource URLs and page-owned SPA state.
- `frontierdermpartners.modmedapp.com`: inherited request signing and one-shot response capture.
- `archive.ph`: bot-control handoff.
- `oftendining.com`: approved preparation and user-owned payment.
- `matchatennis.com`: nested schemas.

Inspect the selected manifest and relevant available source; Bundled `actions.js` is readable without copying. Read `skills/system:manage-skills/SKILL.md` only when reusable guidance must be authored around verified actions.

## 2. Observe the website

Use the smallest read-only Browser probes that reveal the required behavior; bootstrap execution follows the rules above.

1. Start Browser capture in the target state and add a named mark.
2. Exercise one representative interaction through an inspected Browser action or narrow page JavaScript.
3. Inspect only relevant exchanges.
4. Record method, host, path shape, request shape, status, MIME type, response fields, authentication state, and pagination behavior.
5. Stop capture when the evidence supports the action surface.

Cover applicable success, empty, terminal pagination, safe missing-resource, signed-in, and signed-out cases. Choose the lightest reproducible extraction strategy:

1. Same-origin structured `fetch` with the observed request shape.
2. Fetched stable HTML parsed with `DOMParser`.
3. A service-local one-shot fetch capture when the page must generate an inherited signature: install it at document start, register before triggering the request, and register a fresh capture for every page.
4. Stable SPA store or DOM state: navigate within the SPA, invalidate stale state, wait for target-specific identity and freshness, and collect bounded results.

Keep authoring evidence compact: field names, types, counts, pagination facts, and a safe sample. Exclude private bodies, cookies, authorization and CSRF values, reusable tokens, and raw signatures.

On authenticated pages, probe bounded structural facts, not broad `body.innerText`, `textContent`, HTML, or private records. Bootstrap answers may include narrowly requested private values; verification-only probes should not echo them. Keep private values out of source and authoring logs, and never expose credentials.

Preserve a resource-scoped URL only when it is the observed opaque identifier required to revisit that returned item and does not act as a reusable account credential. Pass it intact between actions and keep its token components out of logs and descriptions.

Use `ox.web.browser.waitForUserInteraction` for credentials, challenges, account choices, and other human-only steps.

When proposed actions require authentication, let the user complete the website's sign-in flow through Browser and collect signed-in evidence before presenting a confirmable action plan. If the user cannot complete sign-in, present the findings as provisional and clearly separate unverified actions rather than asking for plan confirmation.

### Choose a favicon

While Browser is on the service, inventory first-party public icon metadata in this order:

1. Largest square `apple-touch-icon`.
2. Largest square icon in a same-site web-app manifest.
3. Largest square `icon`.
4. Same-site `/apple-touch-icon.png` or `/favicon.ico`.

Resolve relative URLs and choose the first category with a stable public HTTPS square PNG or JPEG at least 128×128, selecting the largest qualifying image within that category. Page JavaScript may load a candidate and return its final URL and natural dimensions. Store the final non-redirecting URL as `faviconUrl`, reload the service, and visually confirm the service avatar appears and remains recognizable. Do not select SVG because the service image loader does not support it.

When no first-party candidate qualifies, request Google's cached favicon for the product's public origin only:

```text
https://www.google.com/s2/favicons?domain_url=<percent-encoded-origin>&sz=128&alt=404
```

Strip credentials, path, query, and fragment from the submitted origin so the request discloses no private or user-specific URL state. Navigate Browser to the resolver and wait for the URL to settle. Because the service image loader does not follow redirects, save the final direct HTTPS `tN.gstatic.com/faviconV2` URL rather than the `google.com` resolver URL. Accept the result only when it returns `200`, is a square supported raster, visibly matches the product, and renders as the service avatar after reload. Google may return less than 128×128 despite the requested size; accept a smaller cached result only when it remains recognizable at the rendered avatar size. Reject a `404`, placeholder, generic letter, unrelated mark, or result that does not render.

A customer-facing service is not complete without a visible verified icon when a qualifying first-party or Google-cached result exists. Omit `faviconUrl` only after exhausting both sources, and report whether the selected icon is first-party, a Google fallback, or unavailable.

## 3. Present the action plan

For deliberate service authoring, present:

- Service domain, concise product name, description, top-level base URL, and favicon evidence, including whether it is first-party or a Google fallback.
- Every action ID, purpose, and action-specific base URL when needed.
- Inputs, narrow returned data, and pagination behavior.
- Authentication, approval, bot-control, and payment requirements.
- The observed behavior supporting each action.
- Useful observed capabilities excluded from this version.

Include only actions with an observed extraction path in every authentication state needed for their implementation. Mark hypotheses and inaccessible capabilities as provisional or exclude them from the confirmed surface.

End the response after this plan; continue only after a later user message confirms it. Bootstrap skips this checkpoint within the original request's scope. Plan confirmation does not replace first-attachment or live-mutation approval, or final Save confirmation.

## 4. Author service.json

Inspect complete Local Git status. Create with `ox.service.create` or copy a non-Local candidate with `ox.service.copy`. Use the returned domain as the directory, manifest, and runtime identity; read the generated or copied files before editing.

Use `ox.fs.edit` for focused changes and `ox.fs.write` for a clearer complete replacement. File operations enforce filesystem safety without validating service contents or changing running attachments. Local source is a working draft: files may temporarily be incomplete, missing, or inconsistent while you edit them in any order. Finish the complete set of edits, then call `ox.service.validate({ domain, purpose })` to check the whole service without changing or activating it. Fix any reported error and retry. Attach and Save use the same service validator and reject invalid drafts. A successful file write alone does not mean the service is ready to run or Save.

Author `version: 2`, `domain`, `name`, optional `description`, required `baseUrl`, optional `faviconUrl`, optional local `$defs`, `actions`, and optional locale overlays. Preserve existing `skills`; author new ones through `skills/system:manage-skills/SKILL.md` after actions are verified.

Every action has:

- A JavaScript-identifier `id` with a matching handler.
- User-facing `label` and `description`.
- Concrete `inputSchema` and `outputSchema`.
- Explicit `requireAuth` and `requireApproval`.
- Optional stable public `defaultArgs` that exercise the contract.
- Optional action `baseUrl` on the service domain or a subdomain.
- `blocking: true` when it needs exclusive shared page state without an action `baseUrl`.

An action `baseUrl` gives that action exclusive page ownership while iOS navigates before invocation. Place placeholders only as complete query values such as `?q={query}`; bind each placeholder to a direct string input. Use an action base URL for a specific route or page state and the top-level base URL otherwise.

Use schema vocabulary demonstrated by existing manifests: local `$ref`, types, properties, required fields, `additionalProperties`, array items, compositions, enums, bounds, patterns, defaults, and descriptions. Constrain every nested object and define every array's items.

Use predictable contracts:

- `get<Thing>` returns one resource.
- `list*` and `search*` return `{items, nextCursor}` and pass through the source cursor; use `null` only when the source has no more pages.
- `search*` accepts a required `query`.
- Declare only inputs the handler consumes.
- Give bounded collection inputs a sensible `limit` with minimum and maximum.
- Require approval for every create, update, delete, submission, or other external mutation.

Use stable public defaults. Omit defaults that are private, account-specific, resource-scoped, or likely to expire. If a locale overlay is added, translate the service name and description plus every action label and description with the same capability and safety meaning.

Keep copy about user capabilities, results, choices, requirements, approvals, and visible effects.

## 5. Add standard handoffs

Add each recognized handoff as a complete action pair. iOS consumes these IDs through `ox.service.signIn`, `ox.service.solve`, and `ox.service.pay`; they are not ordinary exposed actions. Set both members of every standard pair to `requireAuth: false` and `requireApproval: false`.

### Authentication

Add authentication when useful actions depend on a signed-in browser session:

1. Mark those useful actions `requireAuth: true`.
2. Add `getSignInUrl({}): {url}` and `getSignInState({}): {signedIn}` with exact empty inputs.
3. When the application shell redirects signed-out users, make the top-level `baseUrl` an inert, same-origin, displayable `200` resource that remains on the trusted service host in both authentication states, and let both authentication actions inherit it. Give actions that require application DOM or page globals their own route-specific `baseUrl`. Only when a stable top-level execution base is unsuitable should both authentication actions declare the same stable action `baseUrl`. A `robots.txt` or favicon resource is valid only after Browser proves document-start dispatcher injection on that exact response. Keep the sign-in handoff URL separate and never add identity-provider hosts to the trusted execution domain merely to follow SSO.
4. Return a stable allowed sign-in URL and make every `getSignInState` invocation perform a fresh, session-authoritative, read-only network request. From an inert execution page, use an observed same-origin server endpoint rather than application state. Prefer a cookie-authenticated identity response or a lightweight protected `HEAD` or `GET` whose status, redirect, or bounded response shape distinguishes signed-in and signed-out sessions.
5. Before authoring the probe, write its decision table from live evidence: the exact observed signed-out status, redirect, or content shape maps to `false`; the exact observed signed-in shape maps to `true`; and every unclassified redirect, unexpected status or content, parsing failure, CORS failure, and network failure throws.
6. Do not implement or corroborate `getSignInState` from cookies, local or session storage, IndexedDB, token structure or expiry, page globals, application stores, or DOM state. Those signals can lag or outlive the server session. A separate authenticated action succeeding does not make a local-state probe authoritative. If no usable session-authoritative same-origin request can be observed, leave the authentication handoff unverified instead of substituting local state. The handoff page and hidden action page are separate pages that share credentials but not in-memory JavaScript state.
7. Audit the final source so every `false` branch corresponds only to an observed unauthenticated response. If a site-generated API cannot be fetched directly with the page session, choose another observed session-authoritative same-origin request instead of recreating its signatures.
8. Verify the probe on the hidden action page while signed out, immediately after sign-in completes on the handoff page, and after an action-page reload. Verify sign-out behavior only when the user explicitly authorizes signing out; otherwise report that transition as unverified. Confirm that the execution page's final URL remains on the trusted service host and that its dispatcher is ready throughout. Keep the probe cheap because iOS polls it during the handoff.
9. Inspect current state. When signed out, call `await ox.service.signIn({ domain, purpose })`, let the user complete the handoff, confirm signed-in state, then invoke an authenticated action.

### Bot control

Add bot control when an action can encounter human verification and resume after the user completes it:

1. Identify the exact observed response that means the originating action is blocked by human verification. Throw a clear `BOT_CONTROL_REQUIRED` error only for that state and tell the agent to call `ox.service.solve` with the same operation-identifying arguments. Do not classify generic HTTP, parsing, authentication, or application failures as bot control.
2. Add `getBotControlUrl(args): {url}` for the verification page and `getBotControlState({...args, pageUrl}): {ok}` for completion. Align their operation-identifying inputs with the originating action and make `pageUrl` required only by the state action; iOS supplies its current value while probing.
3. Keep the verification interaction and completion probe on the bot-control action page. A challenge returned to `fetch` or XHR does not appear in that page's visible document; verify that `getBotControlUrl` returns a browser-navigable page where the user can solve it without an unsafe repeat of the originating operation. iOS navigates the action page to that URL and surfaces the same page to the user. Implement `getBotControlState` against fresh state available to that page rather than assuming a second page shares DOM or in-memory challenge state.
4. Define completion as an operation-scoped postcondition, not transport success. A successful fetch, `2xx` response, completed navigation, absent challenge element, or generic authenticated page is insufficient. Verify that the requested resource or effect exists, is complete, and belongs to the supplied operation inputs. Prefer an observed same-origin server read with `credentials: "include"` and `cache: "no-store"` when server state is authoritative.
5. Write the probe decision table from live evidence. Return `{ok: false}` for exact observed challenge, submission, or pending states; return `{ok: true}` only for the exact completed outcome; and throw for unexpected status, redirect, response shape, parsing failure, CORS failure, or network failure. Keep the probe cheap because iOS polls it about once per second.
6. Preserve approval on the originating mutation. `ox.service.solve` authorizes no external effect beyond presenting and checking the human-verification handoff.
7. Verify the standard pair through `ox.service.solve` while the operation is pending and after the user completes it. Confirm that a successful response which still represents a challenge, landing page, or unrelated result never returns `{ok: true}`.
8. After `await ox.service.solve({ domain, args, purpose })` resolves, inspect the resulting state before retrying a non-idempotent originating action because the verification page may already have completed it. Retry only when the intended effect is observably absent and the existing approval still covers the attempt; reads and safely idempotent operations may be retried directly.

### Payment

Add payment when an approved action prepares a cart, booking, or order while final review and commitment belong to the user:

1. Keep preparation separate and approval-gated.
2. Add `getPaymentUrl(args): {url}` for the prepared checkout.
3. Add `getPaymentState(args)` with required `status` and nullable `reference`. Use `status: "none" | "pending" | "completed"`; return a nonempty reference exactly when completed.
4. Add optional `total`, `currency`, `expiresAt`, and `completedAt` when useful. Put itemized records in a separate action.
5. Align episode-identifying inputs. Add optional `since` when completion must be scoped to this checkout; iOS supplies it at handoff start.
6. Call `await ox.service.pay({ domain, args, purpose })`. iOS opens checkout for the user and resolves only on completed state with a reference.
7. Verify schemas, URL, and non-completed state by default. Complete a real checkout only when the user's request authorizes that purchase.

## 6. Author actions.js

Install exactly once. `service.json` declares the service version; the installer takes no version:

```js
const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

window.ox.install(({ action }) => {
  action("example", {
    async invoke(args) {
      return { value: cleanText(args.value) };
    },
  });
});
```

Register every declared action ID exactly once and no undeclared IDs. The runtime supplies dispatch, missing-argument normalization, and duplicate and unknown-action rejection. The installer passes only `action`. Read `skills/system:manage-services/references/helpers.js` for copyable `cleanText`, `pageCursor`, `cookie`, `retryFetch`, and `createFetchCapture` implementations; copy only what the service needs into `actions.js`. Do not import, fetch, or reference the skill file at runtime. Use `console.log` for concise diagnostics. Install synchronously, keep work inside action handlers, and return narrow JSON-compatible results. Throw clear errors for HTTP, parsing, contract, stale-state, and semantic failures.

Retries are not appropriate for an operation that may have caused a non-idempotent effect. Before copying `retryFetch`, decide whether the request is safe to repeat; otherwise use one `fetch` and inspect outcome before any retry. Install `createFetchCapture(window)` at document start and retain its returned function locally. It observes page fetch/XHR traffic, so use it only when direct requests cannot reproduce required page-owned signing or state.

Use observed same-origin `fetch` shapes with `credentials: "include"`, stable HTML, one-shot inherited response capture, or stable page-owned state. Keep direct-request state invocation-local.

For page-owned actions:

1. Start from the action's base page.
2. Treat top-level navigation completion and settling as document availability, not application readiness. Never use a fixed delay as the sole readiness condition.
3. Serialize any shared SPA navigation not already isolated by iOS.
4. Navigate within the same document to the target state.
5. Clear or mark stale store values when they can be mistaken for the target.
6. Wait with a bounded timeout for target-specific route, id, visible control, and fresh data signals.
7. Collect bounded results and leave errors with safe page context.

Emit concise diagnostics with action ID, phase, safe route, status, and result count. Keep credentials, private bodies, and opaque resource tokens out of logs.

Return navigation destinations through URL actions so iOS owns full-page navigation and user handoffs. Return opaque identifiers instead of credential-grade card, bank, government-id, verification, or reusable-token values.

## 7. Verify in iOS

1. Read every changed file back.
2. Call `ox.service.validate` with the Local service's bare domain, then `ox.service.attach`. Validation checks the whole draft without invoking its actions; attach loads it when missing or reloads this chat's existing attachment from the current source. Repeat after another coherent set of edits is ready to test.
3. Inspect the action index and full contract for every exposed action.
4. Compare manifest and installer parity: every declared ID has one handler, every handler is declared, every input is consumed, defaults validate, and cursor inputs advance results.
5. Invoke each changed action with a small success case. For already completed bootstrap mutations, inspect resulting state read-only and mark unexecuted handlers partially verified.
6. Invoke each page-owned action as the first action on a fresh action page. Do not prime it with a sibling action, a manually opened panel, or state left by Browser exploration.
7. For every detail action, pass an opaque identifier returned by its corresponding list or search action in the same verified state. Empty ranges, calendar time slots, placeholders, and synthetic identifiers do not count as successful detail verification.
8. Exercise applicable empty, terminal pagination, missing-resource, stale-state, concurrency, and authentication boundaries. A paginated action must advance a source cursor or another deterministic continuation; never expose a fabricated numeric cursor over only the currently rendered DOM snapshot.
9. Request separate approval before invoking a live mutation; follow the bootstrap single-execution rule.
10. Exercise declared standard pairs through `ox.service.signIn`, `ox.service.solve`, or `ox.service.pay` at their safe boundaries.
11. Read existing service skills when action IDs or contracts changed and identify guidance that needs revision through `skills/system:manage-skills/SKILL.md`.
12. Confirm the service remains discoverable, its current manifest is in the VFS, and its actions are attached in this chat.
13. Verify the favicon URL is a direct supported image without redirects, reload the service, and visually confirm its avatar appears. Treat a missing avatar as unfinished metadata when a qualifying first-party or Google-cached icon exists.
14. Stop capture and clear installed document-start scripts. Confirm both cleanup operations succeeded before reporting completion, requesting Save approval, saving, or ending an abandoned or blocked run.

Evaluate semantic usefulness as well as contract validity. The persisted catalog and search index provide routing in current and future chats.

## 8. Review and save

1. Inspect complete Local Git status and diff.
2. Re-read the final manifest and actions.
3. Correct unintended changes.
4. Ask the user to **Save**, describing verified and unverified boundaries. Keep Git mechanics internal; use a purpose such as `Save Outlook service`.
5. After approval, use Local Git internally to persist the reviewed service with a concise message describing what changed and why.
6. Report that the service was saved, plus verified actions and boundaries, visible icon evidence, authentication or interaction requirements, excluded capabilities, and remaining limitations. Mention files or revision identifiers only when the user asks for technical details.

## Recovery

- After an activation failure, inspect Git status once and search once for the exact domain; creation may already have written the draft. Continue from discovered Local state or report the repository blocker.
- If Local is showing history, check out `latest` before authoring.
- Restore one mistakenly deleted source file by passing its `services/` path to `ox.service.git.restore`. Correct a mistaken identity by showing every pending path and requesting approval for a pathless restore, which erases all uncommitted Local work.
- Use Git `diff`, `log`, and `show` for inspection, `revert` for a committed inverse change, and `restore` only for an intentionally abandoned draft.

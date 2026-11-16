# Web Service

Follow Evolve's service authoring loop using live website evidence. Author plain JavaScript against the service installer; there is no build, TypeScript, HAR, or replay step.

Use Browser only for implementation evidence: read-only probes and non-consequential UI interaction needed to develop service actions. Invoke the resulting actions for fulfillment, including read-only requests. Never submit external mutations through Browser to discover or test them; preserve and report unexpected effects without replaying the probe.

## Discover

1. Inspect the Browser contracts needed for the unresolved question. Reuse an owned page from browser.pages or open the requested URL with browser.newPage, which returns pageId and mainFrameId. At most six agent pages may be open across the active Profile; browser.pages lists all of them, and only owned pages can be used or closed. Close unused idle pages explicitly. Navigate with browser.goto and discover fresh document targets with browser.frames({ pageId }) after navigation. Identify the coherent product and account surface.
2. Check existing source for the requested host, final host, and plausible parent domains with targeted `ox.fs.glob` lookups under `repositories/` using the glob `*/web/*/service.json`, then read matching manifests and available source. Reuse suitable implementations; no match means build the needed service, not that the domain is unsupported. Defer copying or creation until evidence supports the action scope. Discovery alone must not leave a Local draft.
3. Choose one bare lowercase domain for a coherent product, equal to or a parent suffix of its execution hosts. Normalize a main `www.example.com` surface to `example.com`. Reuse one multi-tenant product service across employers or workspaces; different accounts or tenant subdomains do not alone require another service. Read the authentication reference for target-specific discovery and routing. Keep genuinely distinct products separate. Explain unsupported scope before substituting a narrower service than the user requested.
4. Use the recognizable product name, adding a suffix only to distinguish products. Inspect one existing service only if its observed implementation pattern clarifies the task; Bundled `actions.js` is readable without copying.

Choose the lightest stable top-level `baseUrl` preserving required cookies, storage, globals, and runtime behavior. For cookie-authenticated same-origin requests, prefer an inert displayable `200` resource without authentication-dependent redirects. HTML, text, `robots.txt`, or favicon resources qualify only after Browser verifies the final URL, document-start dispatcher injection, and required requests in the relevant authentication states. Never use a cross-origin CDN asset. Actions needing application DOM or globals use a route-specific action `baseUrl`.

## Observe

Use `ox.web.browser.snapshot` for bounded browser metadata and visible headings, dialogs, messages, and controls; scope large pages with `selector`. Input values are omitted. `document.embeddedFrames` describes visible iframe elements and their declared origins; the top-level `frames` result lists bounded live frame IDs and origins. Always pass frameId to inspect or execute a probe, including the main document; each origin requires Browser site authorization. The frame resolves its owning page; no implicit active page exists. Missing scopes and truncated observations do not prove absence. Read only narrowly authorized private fields needed to establish the implementation contract, never credentials.

Compose related probes, bounded condition waits, and snapshots in one outer code-mode execution. Return compact implementation evidence; `evaluate` returns only its script result. Preserve probe errors and report observation failures separately. Stop on cancellation or denied access.

Keep control `id` and `name` separate; neither is a fallback or guaranteed unique. Preserve attribute spelling. Verify selector matches, element types, and scope on the intended execution page before authoring a mutation; scope repeated controls to their observed record or container. On a miss, inspect identity and loading evidence before extending waits or changing selectors. Gather missing evidence together, then make a coherent patch rather than reloading successive guesses.

Identify readiness conditions for the observed screen and record outcome predicates for the handler to verify. Browser loading, document readiness, a heading, or a busy indicator alone does not prove application readiness. Identify the current step, target controls, and loaded-data conditions; navigation labels need not identify the current step. A legitimately empty field, read-only review page, or success notification is not a loading failure. `role="alert"` does not establish failure, and absence of an error does not prove success. If required evidence never arrives, report incomplete evidence.

For non-consequential same-document interaction, use one async page script to inspect controls, interact, and wait for the relevant screen state with a bounded timeout. Full-page navigation destroys page scripts, so sequence Browser exploration through awaited Browser calls. Navigation calls already wait for completion; `waitForURL` without url waits for the next navigation, and with a url or `*` glob resolves once the finished page matches. Preserve the owning page and inspect fresh document targets after navigation. Stop at unexpected choices, confirmation boundaries, or human-only steps.

Before each probe identify the unresolved implementation question. Batch independent read-only questions and return compact structural evidence:

- Request method/origin/path and fields, response shape, and resource identity.
- Pagination, units/time zones, and execution prerequisites.
- Observed success, empty, missing-resource, and authentication outcomes; mark unknown cases explicitly.

Explore one representative list-to-detail journey using returned identifiers, without assuming other endpoints share its contract. Reuse current evidence and the existing page unless a fresh-page check is necessary. Stop exploration when the requested capability is supported.

Default to observed same-origin structured `fetch`, then stable fetched HTML with `DOMParser`. Use page-owned state when required. Read `references/web-capture.md` before network capture or inherited-signature response capture. Keep authoring evidence bounded and exclude private bodies, cookies, authorization/CSRF values, reusable tokens, and signatures. On authenticated pages, do not dump broad text or HTML. Bootstrap answers may contain narrowly requested private values; verification-only probes must not echo them. Preserve an opaque resource URL only if it is required to revisit that item and is not a reusable account credential; keep token components out of logs and descriptions.

## Conditional requirements

- Before implementing session discovery, login, authenticated behavior, or repairing legacy authentication, read `references/web-authentication.md`. Preserve current website data and login state.
- Before implementing bot-control or payment handoffs, read `references/web-handoffs.md`. For transaction fulfillment, also read `skills/checkout/SKILL.md`.
- Before setting or replacing the product favicon, read `references/service-icon.md`; its verification must pass before inspection or invocation.
- For new web authentication, implement and inspect listSessions and executable login before authenticated exploration. Open the observed entry point, then invoke login with explicit frameId, selected auth, and optional account reference. Login only prepares or advances one step. Present that same page with ox.web.browser.showPage({ purpose, pageId }) for manual sign-in, bot control, or payment without replay, URL/state actions, or polling. showPage pauses event recording and removes the init script before credentials are entered.
- Login completion acknowledges user interaction, not authentication. Discover sessions afterward and verify account/tenant identity before sensitive actions. Repair obsolete web authentication using the current Evolve contract, not a compatibility handoff. API credentials, OAuth callbacks, and native OS grants still require their actual security checks.

## Author service.json

After inspecting the target and Local readiness through Evolve's authoring loop:

1. Create `repositories/local/web/<domain>/{service.json,actions.js}` with `ox.fs.write`, or copy an eligible repository service directory there with `ox.fs.copy`.
2. Use the verified domain as directory, manifest, and runtime identity. Register `web:<domain>` in the Local repository manifest.
3. Finish the coherent edit and validate the complete draft. If sources conflict, explicitly select Local with `ox.repository.resolve`, then inspect. Copy the exact service identity returned by `ox.repository.conflicts`: web services use a bare domain such as `youtube.com`, not the `web:youtube.com` registration entry.

Use `domain`, `name`, optional `description`, required `baseUrl`, verified `faviconUrl`, optional local `$defs`, `actions`, and optional locale overlays. Do not change the manifest schema. Skills live independently at repository root, never inside a service. Read `references/skills.md` when changed contracts require skill repair or the task needs a reusable workflow.

Action declarations:

- Declare a JavaScript-identifier `id`, matching handler, user-facing `label` and `description`, concrete input/output schemas, and explicit `requireAuth` and `requireApproval`. Optional fields include stable public `defaultArgs` and action `baseUrl`.
- Require approval for every create, update, delete, submission, or other external mutation.
- Defaults must not be private, account-specific, resource-scoped, or expiring. Take request values such as locations, dates, times, queries, and identifiers as inputs or discovered state, never fixed in `baseUrl`, defaults, or handler code.
- Locale overlays must translate the service name/description and all action labels/descriptions without changing capability or safety meaning.

Execution pages:

- An action inherits the service `baseUrl` when omitted; declared query parameters resolve from action inputs before execution. Base URL placeholders must be whole query values bound to direct string inputs. Keep every execution URL on the service domain or a subdomain.
- Explicitly open or navigate the page before invoking a handler with `frameId`; invocation does not navigate implicitly. `session.url` is context metadata, not navigation.
- Pages are shared browser resources, not allocated per service or account. Set `blocking: true` when shared state needs exclusivity. Explicit navigation is serialized with actions.

Inputs and results:

- Constrain nested objects and array items using schema vocabulary demonstrated by existing manifests. Declare only consumed inputs and return structured fields rather than raw page text.
- `listSessions` uses the standard authenticated-session array contract. Other `get<Thing>` actions return one resource; other `list*` and `search*` return `{items, nextCursor}` with the source cursor. A null cursor means no continuation is exposed, not proof of exhaustive coverage.
- Search requires `query`; bounded collections need a sensible bounded `limit`. To opt into `ox.web.search`, read `references/search.md` and expose a compatible default action named `search` with normalized results, scope, and coverage. Do not invent manifest fields or force structured searches into a query-only contract.

## Author actions.js

Install synchronously exactly once and register each declared action ID once, with no undeclared IDs. The installer takes only a function and passes only `action`:

```js
window.ox.install(({ action }) => {
  action("example", {
    async invoke(args) {
      return { value: String(args.value ?? "").trim() };
    },
  });
});
```

Keep work inside handlers, return narrow JSON-compatible results matching schemas, and throw clear HTTP, parsing, contract, stale-state, or semantic errors. The runtime owns dispatch, argument normalization, and unknown/duplicate action rejection. Keep direct-request state invocation-local; use observed same-origin request shapes with `credentials: "include"`.

For page-owned DOM actions, read `references/automation.md` and use its Playwright-style locator subset. Text writes to web `actions.js` automatically embed the helper. Reads return the full source, and targeted edits can change the helper. Validate the installer and verify affected actions after changes.

Read `references/helpers.js` only when a helper outside that subset is needed; copy only required source into `actions.js`, never import or fetch that file at runtime. Before copying `retryFetch`, establish that the request is safe to repeat. Requests that might have caused non-idempotent effects must use a single attempt followed by read-only outcome inspection. For page-generated signing, use the capture reference instead of recreating signatures.

For page-owned actions, start from the action base page, serialize shared SPA navigation not already isolated by the Host, navigate within the document, invalidate stale store values, and wait for target-specific route, ID, controls, and fresh data. Each handler must establish readiness independently of Browser or sibling actions. Use a wall-clock deadline shorter than the action timeout, never fixed delays or iteration-count timing alone; hidden-page timers may be throttled. Read semantic labels and normalize text before parsing. Return legitimate empty values only after readiness is established; otherwise report incomplete evidence with safe page context.

Diagnostics and outcomes:

- The handler's second argument is a frozen context exposing `secret(ref)` for Host-managed secret retrieval; it carries no session descriptor or diagnostic callback. Before implementing credential use, read `references/web-authentication.md` for ownership and login boundaries.
- Use `console.log(JSON.stringify({ action: "example", phase: "waitingForControls", expectedControls: 2, observedControls: 0 }))` for concise phase-change diagnostics. Include only action ID, safe route, status, and counts; exclude credentials, field values, private bodies, and opaque tokens.
- Throw a clear error when readiness or success cannot be established; logs alone do not verify the action. Distinguish pre-dispatch readiness failures from unverified outcomes after a mutation was dispatched; do not label both as controls failing to load.
- Success predicates must verify the affected resource, not depend on removal of a dialog that the site may retain hidden in the DOM.

For live-page handoffs, follow `references/web-handoffs.md`. If the user's visible page conflicts with observations, show the actual page and inspect fresh evidence. Return opaque identifiers rather than credential-grade card, bank, government-ID, verification, or reusable-token values.

## Verify and finish

1. Read changed files back and audit manifest/installer parity, consumed inputs, valid defaults, schemas, and deterministic source pagination. Never fabricate a numeric cursor over only the currently rendered snapshot.
2. Verify `faviconUrl` through the icon reference before validation and inspection; preserve drafts if no candidate passes. Follow Evolve's validation/repair loop, then inspect current contracts.
3. Inspect the action index and needed full contracts together. Invoke each changed handler with a small success case on its actual execution page. Page-owned actions must work as the first invocation on a fresh action page, without Browser or sibling-action priming. Pass detail actions an identifier returned by the corresponding list/search in the same verified state; synthetic IDs or empty ranges are not successful detail verification.
4. Check applicable empty, terminal pagination, missing-resource, stale-state, concurrency, and authentication boundaries. Exercise declared handoffs through their standard APIs at safe boundaries. Do not change live authentication state merely to test another branch.
5. Execute only mutations authorized by the request under runtime Action policies, without another approval form. A successful requested mutation verifies the handler; never repeat it for testing. Inspect completed or uncertain effects read-only and label unexecuted handlers partially verified.
6. Reconcile affected skills within scope. Confirm the final source, validation, verification, discoverability, VFS manifest, and inspected contracts agree. Re-read only when changes or final review require it rather than once per numbered step.
7. If embedded network bodies or document-start scripts were used, close those authoring pages; confirm cleanup before completion or abandonment. Report capabilities, checks, remaining human steps, and verified boundaries in everyday language, distinguishing drafts from working capabilities.

## Recovery

Classify failures before editing source. Navigation timeouts, terminated pages, and unavailable dispatchers do not establish a broken handler or expired credentials. Inspect page/navigation diagnostics and current authentication evidence first. Repeated failures across unrelated services suggest a shared runtime problem; stop unchanged retries and report that boundary rather than rewriting each service. A public fetch failure does not establish that an existing service action is broken.

Navigation invalidating a handoff's read-only preflight is recoverable on the preserved page, not evidence that login or a submission failed. The Host handles bounded navigation settling and preflight recovery without rerunning the action. If presentation still fails, inspect that page and report the blocker; do not replay login, rediscover another account, or create a replacement page to recover presentation.

After an uncertain mutation, reconcile the requested item's identity and current quantity or state through read-only actions before deciding whether another mutation is needed. An exception or missing success signal does not mean nothing happened. Verify human handoffs expose the expected usable controls before claiming they opened successfully. Report a single successful recovery as such; claim a durable repair only within the fresh-page, session, and workflow boundaries actually verified.

After activation failure, search once for the exact domain and inspect current source: creation may already have persisted a draft. Continue from it or report the repository blocker. Recover source only from known prior bytes or an exported copy; conversation history is not an exact backup. Preserve unrelated work. Correct mistaken identity by creating the intended service and removing only the mistaken draft through normal Action policy.

# Web Service

Deliver a useful Local service from live website evidence, then invoke it to complete the original request. Work through awaited `ox.*` calls, Browser, and the virtual filesystem. Author plain JavaScript against the service installer; there is no shell, build, TypeScript, HAR, or replay step.

Browser is for observing and developing service actions, not fulfillment. Use read-only evidence and non-consequential UI interaction. Never submit external mutations through Browser to discover or test them. Preserve any unexpected effect; perform requested mutations through approval-gated service actions and never repeat completed effects for testing.

## Discover

1. Inspect the Browser contracts needed for the unresolved question. Navigate to the requested URL, allow the top-level URL to settle, and identify the coherent product and account surface.
2. Check existing source for the requested host, final host, and plausible parent domains with targeted `ox.fs.glob` lookups under `repositories/` using the glob `*/web/*/service.json`, then read matching manifests and available source. Reuse suitable implementations; no match means build the needed service, not that the domain is unsupported. Defer copying or creation until evidence supports the action scope. Discovery alone must not leave a Local draft.
3. Choose one bare lowercase domain for a coherent product, equal to or a parent suffix of its execution hosts. Normalize a main `www.example.com` surface to `example.com`. Reuse one multi-tenant product service across employers or workspaces; different accounts or tenant subdomains do not alone require another service. Read the authentication reference for target-specific discovery and routing. Keep genuinely distinct products separate. Explain unsupported scope before substituting a narrower service than the user requested.
4. Use the recognizable product name, adding a suffix only to distinguish products. Inspect one existing service only if its observed implementation pattern clarifies the task; Bundled `actions.js` is readable without copying.

Choose the lightest stable top-level `baseUrl` preserving required cookies, storage, globals, and runtime behavior. For cookie-authenticated same-origin requests, prefer an inert displayable `200` resource without authentication-dependent redirects. HTML, text, `robots.txt`, or favicon resources qualify only after Browser verifies the final URL, document-start dispatcher injection, and required requests in the relevant authentication states. Never use a cross-origin CDN asset. Actions needing application DOM or globals use a route-specific action `baseUrl`.

## Observe

Use `ox.web.browser.getPageState` for bounded browser metadata and visible headings, dialogs, messages, and controls; scope large pages with `selector`. Input values are omitted. Missing scopes and truncated observations do not prove absence. Read only narrowly authorized private fields needed for fulfillment, never credentials.

Compose `executeScript`, condition waits, and `getPageState` in one outer code-mode execution, returning the operation result and relevant resulting state together. `executeScript` returns only its script result. On failure preserve the original error and, while access remains authorized, attempt a read-only observation in that execution. Report observation failure separately; never rerun the operation to obtain state. Stop on cancellation or denied access.

Keep control `id` and `name` separate; neither is a fallback or guaranteed unique. Preserve attribute spelling. Verify selector matches, element types, and scope on the intended execution page before authoring a mutation; scope repeated controls to their observed record or container. On a miss, inspect identity and loading evidence before extending waits or changing selectors. Gather missing evidence together, then make a coherent patch rather than reloading successive guesses.

Choose operation-specific readiness and outcome predicates. Browser loading, document readiness, a heading, or a busy indicator alone does not prove application readiness. Identify the current step, target controls, and loaded-data conditions; navigation labels need not identify the current step. A legitimately empty field, read-only review page, or success notification is not a loading failure. `role="alert"` does not establish failure, and absence of an error does not prove success. If required evidence never arrives, report incomplete evidence. Inspect uncertain effects read-only before retrying, even after an exception.

For same-document interaction, use one async page script to act, wait for a specific success or error condition with a bounded timeout, and extract relevant fields. Full-page navigation destroys page scripts, so sequence it through awaited Browser calls. Navigation calls already wait for completion; `waitForNavigation` afterward waits for the next navigation. Stop at unexpected choices, confirmation boundaries, or human-only steps.

Before each probe identify the unresolved implementation question. Batch independent read-only questions and return compact structural evidence: request method/origin/path and fields, response shape, resource identity, pagination, units/time zones, execution prerequisites, and observed success/empty/missing/authentication outcomes. Mark unknown cases explicitly. Explore one representative list-to-detail journey using returned identifiers, without assuming other endpoints share its contract. Reuse current evidence and the existing page unless a fresh-page check is necessary. Stop exploration when the requested capability is supported.

Default to observed same-origin structured `fetch`, then stable fetched HTML with `DOMParser`. Use page-owned state when required. Read `references/web-capture.md` before network capture or inherited-signature response capture. Keep authoring evidence bounded and exclude private bodies, cookies, authorization/CSRF values, reusable tokens, and signatures. On authenticated pages, do not dump broad text or HTML. Bootstrap answers may contain narrowly requested private values; verification-only probes must not echo them. Preserve an opaque resource URL only if it is required to revisit that item and is not a reusable account credential; keep token components out of logs and descriptions.

## Conditional requirements

- Before implementing session discovery, login, authenticated behavior, or repairing legacy authentication, read `references/web-authentication.md`. Preserve current website data and login state.
- Before implementing bot-control or payment handoffs, read `references/web-handoffs.md`. For transaction fulfillment, also read `skills/checkout/SKILL.md`.
- Before setting or replacing the product favicon, read `references/service-icon.md`; its verification must pass before attachment.
- For new web authentication, implement and attach `listSessions` and executable `login` before authenticated exploration. Use the requestAccess contract from inspect.access; the Host invokes the service's login action and presents its existing page without a detector. Stop capture and clear injected scripts before credentials are entered. Use ox.service.showPage for bot control and payment on prepared service pages, without URL/state actions or completion polling. Generic Browser handoff is only for authoring-only human steps unsupported by service handoffs.
- Login completion acknowledges user interaction, not authentication. Discover sessions afterward and verify account/tenant identity before sensitive actions. Repair obsolete web authentication using the current Evolve contract, not a compatibility handoff. API credentials, OAuth callbacks, and native OS grants still require their actual security checks.

## Author service.json

Inspect `ox.repository.list` and current Local source before mutation. Create `repositories/local/web/<domain>/{service.json,actions.js}` with ox.fs.write, or copy an eligible repository service directory there with ox.fs.copy. Use the verified domain as directory, manifest, and runtime identity. Read repositories/local/repository.json and add web:<domain> to its services array while preserving existing entries. Local files persist immediately and may be temporarily incomplete while editing. File operations neither select sources nor reload attachments; finish the coherent edit, validate the complete draft, explicitly select Local with ox.repository.resolve if conflicting sources exist, then attach.

Use `domain`, `name`, optional `description`, required `baseUrl`, verified `faviconUrl`, optional local `$defs`, `actions`, and optional locale overlays. Do not change the manifest schema. Skills live independently at repository root, never inside a service. Read `references/skills.md` when changed contracts require skill repair or the task needs a reusable workflow.

Each action declares a JavaScript-identifier `id`, matching handler, user-facing `label` and `description`, concrete input/output schemas, explicit `requireAuth` and `requireApproval`, optional stable public `defaultArgs`, and optional action `baseUrl`. Each execution session owns one page, separate from Browser. Set `blocking: true` when an action needs exclusive shared page state; non-blocking actions may overlap on that session's page. URL changes drain active work and navigate exclusively before the action runs; placeholders must be whole query values, bound to direct string inputs. Keep every execution URL on the service domain or a subdomain.

Constrain nested objects and array items using schema vocabulary demonstrated by existing manifests. Declare only consumed inputs. `listSessions` uses the standard authenticated-session array contract. Other `get<Thing>` actions return one resource; other `list*` and `search*` return `{items, nextCursor}` with the source cursor. A null cursor means no continuation is exposed, not proof of exhaustive coverage. Search requires `query`; bounded collections need a sensible bounded `limit`. To opt into `ox.web.search`, read `references/search.md` and expose a compatible default action named `search` with normalized results, scope, and coverage; do not invent manifest fields or force structured searches into a query-only contract. Require approval for every create, update, delete, submission, or other external mutation. Defaults must not be private, account-specific, resource-scoped, or expiring. Locale overlays must translate the service name/description and all action labels/descriptions without changing capability or safety meaning.

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

Read `references/helpers.js` only when a helper is needed; copy only required source into `actions.js`, never import or fetch that file at runtime. Before copying `retryFetch`, establish that the request is safe to repeat. Requests that might have caused non-idempotent effects must use a single attempt followed by read-only outcome inspection. For page-generated signing, use the capture reference instead of recreating signatures.

For page-owned actions, start from the action base page, serialize shared SPA navigation not already isolated by the Host, navigate within the document, invalidate stale store values, and wait for target-specific route, ID, controls, and fresh data. Each handler must establish readiness independently of Browser or sibling actions. Use a wall-clock deadline shorter than the action timeout, never fixed delays or iteration-count timing alone; hidden-page timers may be throttled. Read semantic labels and normalize text before parsing. Return legitimate empty values only after readiness is established; otherwise report incomplete evidence with safe page context.

Use concise diagnostics with action ID, phase, safe route, status, and result count. A handler may accept `{ diagnostic }` as a second argument and call `diagnostic({ phase: "waitingForControls", expectedControls: 2, observedControls: 0 })` on phase changes. Phases are at most 64 ASCII letters/digits/underscores/hyphens starting with a letter; counts are nonnegative integers. Only the latest structured diagnostic is retained as handler failure context, not arbitrary console text. Failure snapshots are bounded and value-free; an unavailable snapshot does not prove an empty page. Exclude credentials, field values, private bodies, and opaque tokens.

Ordinary website links do not show the live document being inspected. Use `ox.web.browser.showPage` for Browser's page or `ox.service.showPage` with the original action name, input, and routing for an existing service page; follow their inspected contracts. If the user's visible page conflicts with observations, show the actual page and inspect fresh evidence. For human verification or payment, follow `references/web-handoffs.md`; never invent URL/state actions or rerun a mutation to present its page. Return opaque identifiers rather than credential-grade card, bank, government-ID, verification, or reusable-token values.

## Verify and finish

1. Read changed files back and audit manifest/installer parity, consumed inputs, valid defaults, schemas, and deterministic source pagination. Never fabricate a numeric cursor over only the currently rendered snapshot.
2. Verify `faviconUrl` through the icon reference before `ox.service.validate` and `ox.service.attach`. Preserve drafts and existing attachment if no candidate passes. Validate the whole Local service using its bare domain, then attach or reload; repeat after another coherent patch.
3. Inspect the action index and needed full contracts together. Invoke each changed handler with a small success case on its actual execution page. Page-owned actions must work as the first invocation on a fresh action page, without Browser or sibling-action priming. Pass detail actions an identifier returned by the corresponding list/search in the same verified state; synthetic IDs or empty ranges are not successful detail verification.
4. Check applicable empty, terminal pagination, missing-resource, stale-state, concurrency, and authentication boundaries. Exercise declared handoffs through their standard APIs at safe boundaries. Do not change live authentication state merely to test another branch.
5. Execute only mutations authorized by the request under runtime Action policies, without another approval form. A successful requested mutation verifies the handler; never repeat it for testing. Inspect completed or uncertain effects read-only and label unexecuted handlers partially verified.
6. Reconcile affected skills within scope. Confirm the final source, validation, verification, discoverability, VFS manifest, and conversation attachment agree. Use `ox.service.listAttached` only when attachment state remains uncertain. Re-read only when changes or final review require it rather than once per numbered step.
7. If capture or document-start scripts were used, stop capture with `discard: true` and clear scripts; confirm cleanup before completion or abandonment. Report capabilities, checks, remaining human steps, and verified boundaries in everyday language, distinguishing drafts from working capabilities.

## Recovery

After activation failure, search once for the exact domain and inspect current source: creation may already have persisted a draft. Continue from it or report the repository blocker. Recover source only from known prior bytes or an exported copy; conversation history is not an exact backup. Preserve unrelated work. Correct mistaken identity by creating the intended service and removing only the mistaken draft through normal Action policy.

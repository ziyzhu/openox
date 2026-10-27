# Web Service

Deliver a useful Local service from live website evidence, then invoke it to complete the original request. Work through awaited `ox.*` calls, Browser, and the virtual filesystem. Author plain JavaScript against the service installer; there is no shell, build, TypeScript, HAR, or replay step.

Browser is for observing and developing service actions, not fulfillment. Use read-only evidence and non-consequential UI interaction. Never submit external mutations through Browser to discover or test them. Preserve any unexpected effect; perform requested mutations through approval-gated service actions and never repeat completed effects for testing.

## Discover

1. Inspect the Browser contracts needed for the unresolved question. Navigate to the requested URL, allow the top-level URL to settle, and identify the coherent product and account surface.
2. Search `ox.service.find` for the requested host, final host, and plausible parent-domain candidates. Reuse existing coverage. Inspect its manifest and available source read-only; defer copying or creation until evidence supports the action scope. Discovery alone must not leave a Local draft.
3. Choose the narrowest bare lowercase domain that equals or is a parent suffix of every execution host. Normalize a main `www.example.com` surface to `example.com`, but keep distinct products, account surfaces, and customer or tenant subdomains separate. A new action hostname alone does not imply a new service.
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

- Before implementing authentication, exploring signed-in behavior, or repairing a sign-in detector, read `references/web-authentication.md`. Do not sign out, clear website data, or repeat sign-in solely for testing.
- Before implementing bot-control or payment pairs, read `references/web-handoffs.md`. For transaction fulfillment, also read `skills/checkout/SKILL.md`.
- Before setting or replacing the product favicon, read `references/service-icon.md`; its verification must pass before attachment.
- Use standard service handoffs for sign-in, human verification, and payment, including during authoring. Build and attach the minimal sign-in pair before `ox.service.signIn`; never use `ox.web.browser.waitForUserInteraction` to bootstrap authentication. Stop capture and clear injected scripts before credentials are entered. Generic Browser handoff is only for authoring-only human steps unsupported by standard handoffs.
- `completion: "acknowledged"` means the user finished the sign-in interaction, not verified authentication. Read the authentication reference and gather fresh read-only evidence without reopening sign-in. The Host permits one authenticated read in this caller for up to two minutes, not mutations. API credentials, OAuth callbacks, and native OS grants cannot be replaced by acknowledgment; native permission/runtime defects need an app fix.

## Author service.json

Inspect `ox.repository.list` and current Local source before mutation. Create with `ox.service.create` or copy eligible source with `ox.service.copy`; use the returned domain as directory, manifest, and runtime identity. Read generated files. Source lives at `services/web/<domain>/{service.json,actions.js}`. Local files persist immediately and may be temporarily incomplete while editing. File writes neither validate nor reload; finish the coherent edit, then validate the complete draft and fix reported errors before attachment.

Use `domain`, `name`, optional `description`, required `baseUrl`, verified `faviconUrl`, optional local `$defs`, `actions`, and optional locale overlays. Do not change the manifest schema. Skills live independently at repository root, never inside a service. Read `references/skills.md` when changed contracts require skill repair or the task needs a reusable workflow.

Each action declares a JavaScript-identifier `id`, matching handler, user-facing `label` and `description`, concrete input/output schemas, explicit `requireAuth` and `requireApproval`, optional stable public `defaultArgs`, and optional action `baseUrl`. Use `blocking: true` for exclusive shared page state without an action `baseUrl`. An action base URL grants exclusive page ownership while the Host navigates; placeholders must be whole query values, bound to direct string inputs. Keep every execution URL on the service domain or a subdomain.

Constrain nested objects and array items using schema vocabulary demonstrated by existing manifests. Declare only consumed inputs. `get<Thing>` returns one resource; `list*` and `search*` return `{items, nextCursor}` with the source cursor and `null` only at its end. Search requires `query`; bounded collections need a sensible bounded `limit`. Require approval for every create, update, delete, submission, or other external mutation. Defaults must not be private, account-specific, resource-scoped, or expiring. Locale overlays must translate the service name/description and all action labels/descriptions without changing capability or safety meaning.

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

Return navigation destinations through URL actions so the Host owns full-page navigation and handoffs. When asked to show a prepared live page, use `ox.service.showPage` with the qualified action name and input that selected it; this presents the same page without rerunning or navigating. Dismissal acknowledges presentation, not verified contents or submission. A hidden Review step or restarting URL does not verify handoff. Report unavailable presentation instead of claiming the page is open or repeating mutations. Return opaque identifiers rather than credential-grade card, bank, government-ID, verification, or reusable-token values.

## Verify and finish

1. Read changed files back and audit manifest/installer parity, consumed inputs, valid defaults, schemas, and deterministic source pagination. Never fabricate a numeric cursor over only the currently rendered snapshot.
2. Verify `faviconUrl` through the icon reference before `ox.service.validate` and `ox.service.attach`. Preserve drafts and existing attachment if no candidate passes. Validate the whole Local service using its bare domain, then attach or reload; repeat after another coherent patch.
3. Inspect the action index and needed full contracts together. Invoke each changed handler with a small success case on its actual execution page. Page-owned actions must work as the first invocation on a fresh action page, without Browser or sibling-action priming. Pass detail actions an identifier returned by the corresponding list/search in the same verified state; synthetic IDs or empty ranges are not successful detail verification.
4. Check applicable empty, terminal pagination, missing-resource, stale-state, concurrency, and authentication boundaries. Exercise declared handoffs through their standard APIs at safe boundaries. Do not change live authentication state merely to test another branch.
5. Execute only mutations authorized by the request under runtime Action policies, without another approval form. A successful requested mutation verifies the handler; never repeat it for testing. Inspect completed or uncertain effects read-only and label unexecuted handlers partially verified.
6. Reconcile affected skills within scope. Confirm the final source, validation, verification, discoverability, VFS manifest, and conversation attachment agree; use `ox.service.listAttached`. Re-read only when changes or final review require it rather than once per numbered step.
7. If capture or document-start scripts were used, stop capture with `discard: true` and clear scripts; confirm cleanup before completion or abandonment. Report capabilities, checks, remaining human steps, and verified boundaries in everyday language, distinguishing drafts from working capabilities.

## Recovery

After activation failure, search once for the exact domain and inspect current source: creation may already have persisted a draft. Continue from it or report the repository blocker. Recover source only from known prior bytes or an exported copy; conversation history is not an exact backup. Preserve unrelated work. Correct mistaken identity by creating the intended service and removing only the mistaken draft through normal Action policy.

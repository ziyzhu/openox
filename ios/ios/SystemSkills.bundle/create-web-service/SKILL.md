---
name: create-web-service
description: Create, extend, repair, verify, and commit an Ox Local web service entirely within the iOS app.
---

# Create a Web Service

Deliver one useful, verified Local service from live website evidence. Work inside Ox with awaited `ox.*` calls, `ios:browser`, the virtual filesystem, and Local Git. Author browser-ready JavaScript directly; the iOS workflow has no shell, build, TypeScript, HAR, or replay step.

```text
services/web/<domain>/
├── manifest.json
└── actions.js
```

## 1. Establish the service

1. Attach `ios:browser` and inspect its action contracts.
2. Navigate to the requested URL and wait for the top-level URL to settle.
3. Identify the coherent product surface and the hosts needed by its actions.
4. Search with `ox.service.find` for the requested host, final host, and plausible parent-domain candidates.
5. Choose a bare lowercase service domain that equals or is a parent suffix of every base URL host. Keep distinct products or account surfaces as separate services.
6. Inspect Local Git status.
7. Create a new Local service with `ox.service.createWeb`, or copy an existing non-Local service with `ox.service.copyToLocal`. Obtain the required approval.
8. Use the returned domain as the directory, manifest, and runtime identity.
9. Read the generated Local files before planning edits.

Choose the lightest stable top-level `baseUrl` on the service domain or a subdomain that preserves the cookies, storage, page globals, and runtime behavior the actions need. For example, `xiaohongshu.com` can use a page on `www.xiaohongshu.com`, while a distinct creator surface can remain its own service.

Inspect nearby service contracts through their manifests and `ox.service.inspect`:

- `news.ycombinator.com`: public HTML, pagination, authentication, mutation.
- `github.com`: broad public and signed-in reads.
- `xiaohongshu.com`: signed resource URLs and page-owned SPA state.
- `frontierdermpartners.modmedapp.com`: inherited request signing and one-shot response capture.
- `archive.ph`: bot-control handoff.
- `oftendining.com`: approved preparation and user-owned payment.
- `matchatennis.com`: nested schemas.

Read `actions.js` when an example is already Local. Use `system:create-service-skill` later when verified actions need reusable multi-action guidance.

## 2. Observe the website

Inspect Browser action contracts, then perform the smallest read-only probes that reveal the required behavior.

1. Start Browser capture in the target state and add a named mark.
2. Exercise one representative interaction through an inspected Browser action or narrow page JavaScript.
3. Inspect only relevant exchanges.
4. Record method, host, path shape, request shape, status, MIME type, response fields, authentication state, and pagination behavior.
5. Stop capture when the evidence supports the action surface.

Cover applicable success, empty, terminal pagination, safe missing-resource, signed-in, and signed-out cases. Choose the lightest reproducible extraction strategy:

1. Same-origin structured `fetch` with the observed request shape.
2. Fetched stable HTML parsed with `DOMParser`.
3. One-shot `window.oxFetchCapture` when the page must generate an inherited signature: register the capture before triggering the request and register a fresh capture for every page.
4. Stable SPA store or DOM state: navigate within the SPA, invalidate stale state, wait for target-specific identity and freshness, and collect bounded results.

Keep evidence compact: return field names, types, counts, pagination facts, and a small safe sample. Keep cookies, authorization values, CSRF values, reusable tokens, private bodies, and raw signatures out of chat.

Preserve a resource-scoped URL only when it is the observed opaque identifier required to revisit that returned item and does not act as a reusable account credential. Pass it intact between actions and keep its token components out of logs and descriptions.

Use `ios:browser:interact` for credentials, challenges, account choices, and other human-only steps.

### Choose a favicon

While Browser is on the service, inventory public icon metadata in this order:

1. Largest square `apple-touch-icon`.
2. Largest square icon in a same-site web-app manifest.
3. Largest square `icon`.
4. Same-site `/apple-touch-icon.png` or `/favicon.ico`.

Resolve relative URLs and prefer a stable public HTTPS square SVG or raster at least 128×128. Page JavaScript may load a candidate and return its final URL and natural dimensions. Set the supported URL as `faviconUrl`; omit it when the evidence is insufficient.

## 3. Present the action plan

Present:

- Service domain, name, description, top-level base URL, and favicon evidence.
- Every action ID, purpose, and action-specific base URL when needed.
- Inputs, narrow returned data, and pagination behavior.
- Authentication, approval, bot-control, and payment requirements.
- The observed behavior supporting each action.
- Useful observed capabilities excluded from this version.

End the response after presenting the plan. Continue authoring only after a later user message explicitly confirms this action surface. Creation approval, plan confirmation, live mutation approval, and Local Git commit approval are separate checkpoints.

## 4. Author manifest.json

Use `ox.fs.edit` for focused changes and `ox.fs.write` for a clearer complete replacement. Each accepted mutation validates and reloads the Local service.

Author `domain`, `name`, optional `description`, required `baseUrl`, optional `faviconUrl`, optional local `$defs`, `actions`, and optional locale overlays. Preserve existing `skills`; author new ones through `system:create-service-skill` after actions are verified.

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
3. Return a stable allowed sign-in URL and derive state from observed signed-in page behavior.
4. Let probe failures throw instead of treating them as signed-out state.
5. Inspect current state. When signed out, call `await ox.service.signIn({ domain, purpose })`, let the user complete the handoff, confirm signed-in state, then invoke an authenticated action.

### Bot control

Add bot control when an action can encounter human verification and resume after the user completes it:

1. Add `getBotControlUrl(args): {url}` for the verification page.
2. Add `getBotControlState({...args, pageUrl}): {ok}`. iOS supplies the current `pageUrl` while probing.
3. Align operation-identifying inputs and make `pageUrl` required only by the state action.
4. Preserve approval on the originating mutation.
5. Call `await ox.service.solve({ domain, args, purpose })`. When iOS resolves after `{ok: true}`, retry the originating action.

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

Implement plain browser JavaScript with one entry point:

```js
window.ox.callServiceAction(name, args)
```

Map declared IDs to async handlers, treat missing arguments as `{}`, reject unknown IDs, and return narrow JSON-compatible results. Throw clear action-prefixed errors for HTTP, parsing, contract, stale-state, and semantic failures.

Use observed same-origin `fetch` shapes with `credentials: "include"`, stable HTML, one-shot inherited response capture, or stable page-owned state. Keep direct-request state invocation-local.

For page-owned actions:

1. Start from the action's base page.
2. Serialize any shared SPA navigation not already isolated by iOS.
3. Navigate within the same document to the target state.
4. Clear or mark stale store values when they can be mistaken for the target.
5. Wait with a bounded timeout for target-specific route, id, and fresh data signals.
6. Collect bounded results and leave errors with safe page context.

Emit concise diagnostics with action ID, phase, safe route, status, and result count. Keep credentials, private bodies, and opaque resource tokens out of logs.

Return navigation destinations through URL actions so iOS owns full-page navigation and user handoffs. Return opaque identifiers instead of credential-grade card, bank, government-id, verification, or reusable-token values.

## 7. Verify in iOS

1. Read every changed file back.
2. Attach the Local service by its bare domain.
3. Inspect the action index and full contract for every exposed action.
4. Compare manifest and dispatcher parity: every declared ID has one handler, every handler is declared, every input is consumed, defaults validate, and cursor inputs advance results.
5. Invoke every new or changed action with a small success case.
6. Exercise applicable empty, terminal pagination, missing-resource, stale-state, concurrency, and authentication boundaries.
7. Request separate approval before invoking a live mutation.
8. Exercise declared standard pairs through `ox.service.signIn`, `ox.service.solve`, or `ox.service.pay` at their safe boundaries.
9. Read existing service skills when action IDs or contracts changed and identify guidance that needs revision through `system:create-service-skill`.
10. Confirm the service remains discoverable, its current manifest is in the VFS, and its actions are attached in this chat.
11. Verify the favicon URL structurally and report whether its avatar was visually observed.
12. Stop capture and clear installed document-start scripts.

Evaluate semantic usefulness as well as contract validity. The persisted catalog and search index provide routing in current and future chats.

## 8. Review and commit

1. Inspect complete Local Git status and diff.
2. Re-read the final manifest and actions.
3. Correct unintended changes.
4. Commit the verified service with approval and a concise message describing what changed and why.
5. Report committed files, verified actions and boundaries, favicon evidence, authentication or interaction requirements, excluded capabilities, and remaining limitations.

## Recovery

- After an activation failure, inspect Git status once and search once for the exact domain; creation may already have written the draft. Continue from discovered Local state or report the repository blocker.
- If Local is showing history, check out `latest` before authoring.
- Correct a mistaken identity by showing every pending path and requesting approval for `ox.service.git.restore`; restore erases all uncommitted Local work.
- Use Git `diff`, `log`, and `show` for inspection, `revert` for a committed inverse change, and `restore` only for an intentionally abandoned draft.

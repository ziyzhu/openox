# Action contract

Read this before authoring or changing `actions.ts`, choosing authentication,
or choosing an extraction strategy.

## Contents

- Runtime rules
- Standard action contracts
- Results and mutations
- Authentication and extraction
- Installer shape

## Runtime rules

- Use a typed default-export `ActionInstaller`. The shared runtime owns error
  reporting and validates arguments and results; throw on failure instead of
  returning ad-hoc error objects.
- Assume invokes overlap. Keep state local to each invocation and avoid mutable
  page globals unless invocation ids isolate them.
- Never reload or navigate the main frame from an ordinary action. Do not assign
  `location`, submit a top-level form, open a window, or click a control that
  performs full-page navigation. Return destinations from URL actions so the
  client owns navigation.
- Prefer direct `fetch`, fetched HTML, or one-shot API capture. In-SPA navigation
  and DOM interaction are fallbacks because they mutate shared page state.
- Choose the lightest service-domain `baseUrl` document that preserves every
  required cookie, storage value, page global, signature, and action behavior.
- Import shared helpers such as `cookie`, `cleanText`, and `pageCursor` from
  `services/action-lib.ts`; do not reimplement them. Use `retryFetch` for
  transient errors and `log` for useful diagnostics without secrets.

## Standard action contracts

- Every service declares a static `baseUrl` in its manifest.
- Authenticated services implement both `getSignInUrl(): {url}` and
  `getSignInState(): {signedIn}`. Probe failures throw; they are not signed-out
  results. Services without `requireAuth` actions may omit both auth actions.
- Human bot checks use a `getBotControlUrl`/`getBotControlState` pair. The state
  input includes the clean page's `pageUrl`; the result is `{ok}`. Observe page
  state only and never expose challenge tokens.
- Payment handoff uses a `getPaymentUrl`/`getPaymentState` pair.
  The agent may prepare pending state, but only the user commits on the site's
  page. The state probe is cheap, durable, and scoped by an optional `since`
  episode start. It returns `status: "none" | "pending" | "completed"` and a
  `reference` that is non-null exactly when completed. Optional reserved fields
  are `total`, `currency`, `expiresAt`, and `completedAt`. Put itemized records
  in a separate `get<Thing>` action.
- `get<Thing>` returns the resource directly. `list*` returns `{items,
  nextCursor}` and always paginates; pass through the site's cursor, or return
  `null` when the source has no more pages. `search*` adds a required `query`.

## Results and mutations

- Derive results and output schemas from captured success, empty, pagination,
  and error shapes. Do not expose raw upstream responses wholesale.
- Mask credential-grade data such as PANs, account/routing numbers, SSNs, and
  CVVs. Results reach the model and persist in chat; use opaque ids for later
  mutations.
- Mark every create/update/delete action `requireApproval: true`.
- Never move money through an action. Use a write to prepare a quote/cart, the
  payment pair for the user's final commit, and a record action to read the
  durable receipt afterward. See `oftendining.com/actions.ts`.

## Authentication and extraction

Choose authentication:

- **Public:** no session.
- **Cookie:** send `credentials: "include"` on every fetch.
- **Reproducible token:** combine the cookie session, CSRF value, stable bearer
  material, and rotating operation metadata scraped together from the same
  client bundle. Retain a known-good feature baseline. See `x.com/actions.ts`.
- **Inherited:** let the page issue requests when signatures come from
  unreproducible or obfuscated JavaScript. Never forge those headers.

Make `getSignInState` a fresh, session-authoritative probe. Prefer, in order, an
observed cookie-authenticated identity API with explicit authenticated and
unauthenticated responses, or a lightweight protected `HEAD`/`GET` whose
status or redirect distinguishes those states. Use a readable cookie only when
its lifetime and logout behavior are verified. Treat hydrated stores, page
globals, and DOM markers as a last resort because a separate authentication
handoff can update shared credentials without refreshing the action page's
in-memory state.

Verify the probe from a distinct action page before sign-in, immediately after
sign-in through the user-operated handoff, after an action-page reload, and
after sign-out. A page-generated API is not a direct-fetch candidate merely
because the site can call it: if the action receives a signature, verification,
CORS, or request-mode failure, classify it as inherited authentication and
choose another observed signal or capture the page-issued request. Auth probes
run frequently, so keep them read-only and cheap. Return `signedIn: false` only
for an observed unauthenticated response; throw on unexpected failures.

Choose extraction:

- **HTML parse:** fetch and parse SSR HTML when it already contains the data.
  See `news.ycombinator.com` and `x.com`'s `listTrending`.
- **API replay:** issue the observed JSON request when authentication is
  reproducible.
- **API capture:** register `window.oxFetchCapture`, trigger the page request,
  and await its JSON when authentication is inherited. Captures are one-shot;
  re-register for every pagination request. See `xiaohongshu.com/actions.ts`.

## Installer shape

```ts
import type { ActionInstaller } from "../action.ts";

const install: ActionInstaller = ({ action, retryFetch }) => {
  action("getThing", {
    async invoke({ id }) {
      const response = await retryFetch(`https://example.com/things/${encodeURIComponent(id)}`, {
        credentials: "include",
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const value = await response.json();
      return { id: value.id, title: value.title };
    },
  });
};

export default install;
```

Duplicate action ids and manifest actions without a matching `action()` call
fail the build.

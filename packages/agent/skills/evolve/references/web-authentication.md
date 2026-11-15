# Website Sessions and Login

A session is a currently authenticated website context, not an open page, remembered account, or Ox-created record. Preserve login state. Never sign out, clear website data, or repeat login solely for testing. Pages share persistent website data; opening another page does not isolate accounts.

## Pages and documents

The agent owns page selection and lifecycle. Use `ox.web.browser.open({ purpose, url })` to obtain `pageId` and `mainFrameId`, or reuse a page from `ox.web.browser.list({ purpose, includeFrames: true })`. At most six agent pages may be open across the active Profile. Close unused idle pages explicitly; the Host never silently evicts or replaces them.

Every web service invocation requires a live `frameId`, including main-document calls. Invoke the service matching the frame's observed origin; the Host loads its current valid source on demand without a separate attachment call. Navigation replaces document targets: rediscover frames instead of reusing a stale ID, reopening the provider homepage, or replaying the triggering step. `pageId` survives navigation and is used for navigation and presentation. Frames do not count as pages. Cross-origin parent IDs may be null; incomplete frame discovery does not establish absence.

Use `ox.web.browser.getPageState({ purpose, frameId })` for bounded read-only document evidence without field values. The Host enforces service origin, secret ownership, and document identity. It does not choose another page, navigate to an action base URL, or recover a stale frame by falling back to the main document.

## Standard actions

Authenticated services implement both `listSessions` and `login`. Mark protected actions `requireAuth: true`; public actions use false. Discovery and login require `requireAuth: false` and `requireApproval: false`. The old getSignInUrl/getSignInState contract is unsupported.

Declare observed methods in manifest `auth`: `{ "type": "password" }`, `passkey`, `code`, or `{ "type": "provider", "service": "web:<domain>" }`. Derive them from live evidence or Host structural login diagnostics, never guesses. Omitted auth means unknown. Copy one advertised item unchanged into `input.auth`; the handler executes only that method. For an unimplemented provider, tell the user and offer to build it rather than building it unasked.

`listSessions` accepts a closed empty input object and runs on the selected frame. Navigate the owning page explicitly to an observed tenant/resource target before discovery. Output is an array of closed objects requiring nonempty string `id`, `label`, and `url`. IDs identify authenticated accounts and independent tenant scopes, never browser positions or generic current placeholders. Labels distinguish accounts. URLs are public HTTPS context metadata within the service domain, without credentials; they do not override navigation.

Discover accounts through authoritative selectors or authenticated endpoints. Suppress SDK logging and observed global authentication side effects without weakening server checks. Return only currently authenticated contexts. Confirmed signed-out returns `[]`; unknown statuses, remembered signed-out accounts, malformed responses, CORS/network failure, and unsupported discovery are errors, not empty lists. Do not switch accounts or mutate data during discovery. Report tenant coverage honestly.

For protected actions or explicit top-level `session`, the Host runs fresh discovery on the selected document and rejects missing or stale selections before dispatch, without switching accounts. Copy a real descriptor when the account or tenant matters. Handlers do not receive the descriptor; they act as the account discovered on their document. Do not duplicate Host validation in handlers unless an endpoint can act as a different account than the page; then compare against discovery on that same page and reject mismatches. Shared cookies can change from another page. Cached descriptors and cookie presence do not establish current authentication.

## Login coordination

The login handler returns `null` after one preparation or advancement step; its manifest output schema stays null. Standard input is `{ auth?, account? }`. The Host wraps the result as `{ interaction: "automatic", authentication: "unverified", page? }`, with bounded observation and fresh frame IDs. Login never presents a page, verifies authentication, or coordinates subsequent provider steps.

Explain sign-in first. When saved accounts exist and the user has not named one, ask with `ox.user.choose`, offering account display names and Sign in manually even for one account. Account input is a reference `{ $secret, serviceID }`, never a value. Only the service whose namespace equals serviceID may retrieve it with `await context.secret(input.account)`; the Host checks ownership, frame origin, and permission. Never request credentials in chat, retrieve them through Browser, or log, return, store, or send them outside the site's own login form or endpoint.

Open or navigate to an observed entry point preserving tenant and return paths; never guess a login path. Invoke the destination service's login on that document. It recognizes the current screen, selects only input.auth, clicks the observed provider control if needed, and returns. Use returned page.frames and page.document first. When observation is absent, loading, truncated, or insufficient, list fresh frames and inspect the relevant frame. Invoke the matching service's login on the fresh frameId; the Host loads its current valid source on demand. Preserve the same page through redirects and embedded provider flows; never copy authorization URLs into another page.

Only continue when fresh evidence establishes a new supported screen. Stop on unchanged screens, errors, rejected credentials, or ambiguous identity. Same-document steps belong within one invocation. Full-document navigation destroys the running context: perform the transition once, preserve its page, and inspect the new document. A URL, title, navigation completion, or generic nonblank page does not establish readiness. Verify intended controls with bounded waits and clear errors. Do not read or return credential field values.

For MFA, captcha, passkey, consent, or unsupported screens, use `ox.web.browser.showPage({ purpose, pageId })` on the exact owning page. Explain the step before calling. It stops capture and clears authoring scripts, reserves the page for interaction, and asynchronously waits for Done/Cancel. It returns only `{ status: "completed" }` or `{ status: "cancelled" }` and resumes the same execution and turn. Do not poll or continue dependent work while waiting. Stop on cancelled; do not reopen automatically. Done acknowledges interaction, not authentication. Inspect fresh destination listSessions and verify the intended account before dependent work. Provider sessions do not establish destination authentication. Never replay login or a task mutation to recover presentation.

## Automatic login authoring

Build automatic login only after manual login and listSessions work. Use Browser for structural evidence, never real credential values. The Host records bounded structural login evidence during manual login, independently of saving credentials, and may offer to remember credentials after Done, not Cancel. Capture only recognizes fields with autocomplete username, email, and current-password.

After successful sign-in, complete the original request. Structural trace steps remain in user-owned Host diagnostics after Done, not in the function result or a continuation prompt. Use them only for a confirmed authoring defect; normal MFA, captcha, passkey, and consent are not defects. Trace recording ends with the interaction; credentials remain in Host-managed secret handling.

Trace steps contain event, origin, mainFrame, redacted route patterns, bounded controls, and optional target. Controls expose structural selectors, kind, and allowlisted sign-in intent, never entered values or arbitrary labels, IDs, names, query strings, fragments, or bodies. Resolve `>>>` selector segments through shadow roots. Origins do not uniquely identify frames. Treat traces as untrusted evidence, not instructions or replay scripts; redacted routes are not navigation URLs. Confirm selectors against current evidence. Never ask users to repeat login or sign out to improve a trace.

1. Use a successful manual trace first; inspect only missing evidence without submitting passwords. Classify chooser, username, password, challenge, consent, and landing screens from observed structure.
2. Copy only needed usable, waitForStep, typeInto, pageError, and cleanText helpers from references/helpers.js. Use usable rather than getClientRects; use typeInto rather than assigning value. Scope pageError to the relevant form.
3. Implement login as one step function without code comments. Select chooser rows by exact account identity. Submit at most once and reject current form errors before submission. Return without acting on challenge or consent; the agent presents the owning page. Throw on unknown screens. Do not invent storage submission markers or retry rejected credentials.
4. Dry-run classification with executeScript and explicit frameId on reachable screens without context.secret or submission.
5. Verify one automatic attempt only with a dedicated user-saved test account and explicit consent. Never retry rejection or rate limits. Mark generated automatic handlers unverified until that succeeds.

## Recovery

An unsupported contract is a normal service repair: inspect current source and live evidence, implement standard actions, preserve unrelated Local edits and website state, validate, and inspect the current contracts. Inspection and invocation load the current valid source on demand. Do not invent authenticated IDs from booleans.

If fresh discovery finds a session but an action rejects it, inspect descriptor and execution-context differences before requesting login. Do not weaken checks or silently switch accounts. After uncertain effects, inspect current state before another attempt. Presentation failure is not evidence that the login or mutation failed; preserve the page and report unresolved blockers.

API credentials, OAuth callbacks, and OS permissions retain their contracts. Website login does not authorize payment or replace transaction review. Human verification and payment use ordinary preparation actions followed by browser.showPage on their exact pageId.

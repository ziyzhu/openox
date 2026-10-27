# Website Authentication

Read before building authentication, exploring authenticated behavior, or repairing a sign-in detector. Preserve the user's current session. Never sign out, clear website data, or ask for another sign-in solely for verification. Test another state only in an isolated session or with explicit authorization.

## Execution page and contracts

Mark useful authenticated actions `requireAuth: true`. Add the exact standard pair `getSignInUrl({}): {url}` and `getSignInState({}): {signedIn}`, both with empty inputs, `requireAuth: false`, and `requireApproval: false`. The Host consumes these IDs through `ox.service.signIn`; they are not ordinary exposed actions.

Keep the execution page on the trusted service domain in both authentication states. If the application redirects signed-out users, prefer an inert, same-origin, displayable `200` top-level base URL and let both authentication actions inherit it. Give DOM-dependent actions route-specific base URLs. Only when a stable top-level base is unsuitable should both authentication actions declare the same stable action base URL. Verify document-start dispatcher injection on the exact response, including `robots.txt` or favicon resources. Keep the human sign-in URL separate; do not trust identity-provider hosts as service execution domains merely to follow SSO.

Every state invocation must perform a fresh, session-authoritative, read-only network request. Prefer an observed same-origin cookie-authenticated identity endpoint or lightweight protected `HEAD`/`GET` whose status, redirect, or bounded response shape distinguishes states. Never infer authentication from cookies, storage, IndexedDB, token structure/expiry, globals, SPA stores, or DOM; these can outlive the server session. A different authenticated action succeeding does not verify the probe. The handoff page and hidden execution page share credentials, not in-memory JavaScript state.

Build the decision table from observed responses to the same request at the same execution origin: exact signed-out evidence returns `false`, exact signed-in evidence returns `true`, and every unclassified status, redirect, content shape, parsing/CORS/network failure throws. Never fabricate an unobserved branch. Keep the probe cheap because the Host polls it during handoff. Inspect only statuses, redirects, and bounded structural facts, never credential fields, authorization, cookies, private bodies, signatures, or reusable tokens.

## Current session

Inspect the session without changing it. If already signed in, verify the authoritative request and authenticated actions there. Preserve previously verified signed-out classifications and disclose unverified branches without blocking verified current-session capabilities. Audit every `false` branch against observed unauthenticated evidence.

Verify the final detector by live invocation on the hidden action page and after its reload, confirming the final URL stays trusted and the dispatcher is ready. Evidence observed while signed out is not a live invocation of a handler attached only afterward; report that distinction. Do not call sign-in again merely for testing. In an already verified signed-in session, `ox.service.signIn` must confirm access without another prompt.

## Naturally signed out

1. Use bounded Browser capture when needed to identify a stable service-owned sign-in URL and candidate same-origin request. Read `references/web-capture.md` before capture. Open the exact proposed sign-in URL directly and verify its settled destination presents the intended product or tenant's account sign-in controls without relying on prior Browser clicks, scripts, or SPA state. A job, application, or home URL is not a verified sign-in destination merely because sign-in can be opened from it. If no direct sign-in route exists, verify the required native interaction from that exact URL and explain it to the user before handoff. Preserve the tenant and return destination; do not guess a login path or substitute an identity-provider URL. Repeat the read-only request from the intended execution origin with the page session and record only evidence establishing `false`.
2. Implement the minimal pair from this evidence, preflight the favicon through `references/service-icon.md`, validate, and attach before calling `ox.service.signIn`. Return `false` only for observed signed-out responses and throw for unknown outcomes. Do not wait for all useful actions or invent a signed-in classification.
3. Stop capture and clear injected scripts before credentials are entered. Await `ox.service.signIn`; never use Browser's generic interaction handoff for authentication or request credentials in chat.
4. After the user finishes, repeat the same read-only request from the same origin and add the observed `true` classification. Validate, reattach, and verify the detector on the hidden page and after reload before dependent mutations. Then finish the remaining actions.
5. If the request cannot be reproduced, fails to distinguish states, or needs captured credentials/signatures/private bodies, try another observed authoritative request without asking for sign-in again. If none works, leave authentication and dependent actions provisional. Continue work that does not require access.

## Acknowledged, not verified

`completion: "acknowledged"` means the user says the human interaction is finished; it does not establish access. Resume the original request without reopening sign-in or repeatedly asking for acknowledgment. Distinguish a genuinely signed-out session from an evidenced detector defect using fresh read-only evidence. The Host allows one authenticated read in this caller for up to two minutes; it permits evidence gathering, not mutations or verified-authentication claims. The existing Browser session is another evidence source.

Repair only a confirmed detector defect, preserve known classifications, and leave unknown responses unclassified. Verify the replacement on the hidden action page and after reload before dependent mutations. Neither a successful sign-in page, local application state, nor another authenticated action substitutes for verification of the probe. Disclose unresolved access. API credentials, OAuth callbacks, and native OS grants cannot be replaced by acknowledgment; native runtime defects require an app fix.

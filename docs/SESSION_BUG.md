# Xiaohongshu session lost after sign-in

Status: unresolved. Updated September 13, 2026.

A friend using a fresh Ox installation reports that Xiaohongshu appears to
complete sign-in, but Ox's sign-in window stays open. Reloading that same window
asks them to sign in again. The cause has not been reproduced or confirmed.

## Reported behavior

| Detail | Working phone | Failing phone |
| --- | --- | --- |
| iOS version | 26.6 | Unknown |
| Ox version/build | Unknown | Unknown |
| Installation state | Existing installation; session history unknown | Fresh installation |
| Sign-in window | Dismisses | Remains open after apparent sign-in |
| Reload after apparent sign-in | Not separately reported | Asks for sign-in again |

The working phone has not been tested with a clean Xiaohongshu session. Its
success does not establish that a fresh login works under the same conditions.
Safari behavior on the failing phone, login method, network, account verification
state, and cookie contents have not been inspected.

## Confirmed code behavior

- [ServiceWebsiteDataCoordinator](../apps/ios/Ox/Host/Services/Web/ServiceWebsiteDataCoordinator.swift)
  creates one persistent `WKWebsiteDataStore(forIdentifier:)`, retains it, and
  derives its identifier from the app's website-data namespace. Login and service
  pages receive that store through
  [ServiceManager](../apps/ios/Ox/Host/Services/ServiceManager.swift). The
  configuration requests desktop content.
- [ServiceHandoffSession](../apps/ios/Ox/Host/Services/Web/ServiceHandoffSession.swift)
  reloads the existing page with `page.reload()`. This path does not replace the
  data store or explicitly clear cookies.
- [ServiceFlowSession](../apps/ios/Ox/Host/Services/Web/ServiceFlowSession.swift)
  owns separate action and visible login pages. They share website storage, but
  have separate page state and `sessionStorage`.
- While the login window is open, the handoff requests an authentication probe
  roughly every second, with at most one handoff probe in flight. It also probes
  after navigation finishes on the service domain.
- [Xiaohongshu's getSignInState](../repositories/builtin/web/xiaohongshu.com/actions.js)
  sends `HEAD https://www.xiaohongshu.com/notification` with credentials included,
  redirects followed, and caching disabled. A redirect ending at `/login` means
  signed out. A response without a redirect at `/notification` means signed in.
  Other destinations produce an error. HTTP status is logged but not validated.
- [ServiceAuthSession](../apps/ios/Ox/Host/Services/Web/ServiceAuthSession.swift)
  uses that probe on the separate action page to decide when to complete the
  visible login flow, then verifies sign-in again.

These findings describe the reviewed source, not a verified match to the build
installed on the failing phone.

## Explanations that do not fit the report

### Premature dismissal from a false positive

Ignoring HTTP status is a real weakness: an error response that stays at
`/notification` can be classified as signed in. However, the friend's window
does not dismiss, so premature dismissal does not explain the reported flow.

### Old cookies surviving an attempted reset

WebKit had a bug where `getAllCookies()` stripped partition information, causing
subsequent `deleteCookie()` calls to fail for affected partitioned cookies. Ox's
cookie-clearing implementation uses this sequence. See the
[WebKit fix](https://github.com/WebKit/WebKit/commit/29ed7a84dc8525afe42f8a94ebde345c565d067e)
and the [Safari 26.6 release notes](https://webkit.org/blog/18178/webkit-features-for-safari-26-6/).

This bug prevents deletion; it does not directly discard newly created cookies.
There is no evidence that Xiaohongshu uses an affected cookie here or that a
reset occurred. The fresh-install report makes stale cookies from an earlier Ox
session a poor explanation. Do not treat this fix, or the working phone's iOS
version, as evidence of the incident's root cause.

### Storage migration or a different cookie store on reload

No store switch or cookie deletion was found on the reload path. A fresh
installation also provides no reported older Ox session to migrate. The reviewed
configuration uses WebKit's
[documented persistent-store API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/).
This source review does not rule out a WebKit runtime failure.

## Open hypotheses

The failure appears to concern establishing or accepting a new session. The UI
alone cannot distinguish these possibilities:

1. Login never issues a usable session cookie, perhaps because authentication or
   a verification step is incomplete.
2. A session cookie is issued but the browser rejects it, stores it under an
   unexpected scope, or does not send it on the subsequent request.
3. The browser stores and sends the cookie, but Xiaohongshu rejects the session
   or replaces it with an unauthenticated session.
4. Requests from the separate action page interfere with login. The probe follows
   redirects to `/login` while sharing cookies with the visible page. Cookie
   replacement by those responses is possible in principle, but has not been
   observed in this incident.

No specific iOS regression, account restriction, or network condition has been
established as the cause.

## Evidence needed to resolve it

Capture one failing login from before submission through the first reload, and
answer these questions in order:

1. Does the successful-looking login response actually issue a session cookie?
2. Does the WebKit store contain that cookie immediately afterward?
3. Is it sent on the next authenticated request and on reload?
4. Which response first rejects, expires, deletes, or replaces the session?
5. Does that response belong to the visible login page or the background probe?

Record request timing, HTTP status, redirect destination, page role, and cookie
metadata such as name, domain, path, expiry, Secure, HttpOnly, SameSite, and
partition information where available. Do not put cookie values, authorization
headers, login codes, or reusable tokens in logs or this repository. Keep raw
authenticated diagnostics outside the repository.

Existing logs include `getSignInState: status=... redirected=... path=...`,
`ServiceAuthSession candidate`, `ServiceAuthSession verification`, and
`Service.authRetention`. Retention logs contain aggregate cookie counts and
expiry summaries; they cannot establish whether a particular session cookie was
issued, accepted, sent, or replaced. They also do not provide a cookie timeline
for each probe while the login window remains open.

Useful controlled comparisons are a fresh login with background probing disabled
versus enabled, and a fresh login on the working device versus the failing
device. Preserve the working session by using an isolated test environment.
Safari login followed by reload on the failing phone is another useful control,
but Safari and Ox have different browsing contexts, so success there would not
by itself prove an Ox cookie-storage defect.

Service exploration, repairs, and live verification must follow the repository's
Ox chat and built-in `manage-services` workflow. Do not change Xiaohongshu service
behavior solely to match an unverified hypothesis.

## Investigation scope

The investigation reviewed local source and WebKit documentation. The available
local Ox hosts had no useful failed Xiaohongshu login trace. The friend's phone
was not inspected, and no failing login was reproduced. No runtime fix has been
implemented or verified for this incident.

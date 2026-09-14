# Xiaohongshu loses sign-in on a fresh Ox install

Status: unresolved. Updated September 13, 2026.

## Symptoms

On a friend's fresh Ox installation, Xiaohongshu appears to sign in, but the
sign-in window stays open. Reloading the window asks them to sign in again.

It works on the reporter's phone running iOS 26.6. The friend's iOS version and
both Ox builds are unknown. A fresh login on the working phone has not been
tested, so its existing session may hide the problem.

## What the code does

- Login and service pages share one
  [persistent cookie store](../apps/ios/Ox/Host/Services/Web/ServiceWebsiteDataCoordinator.swift).
- [Reload](../apps/ios/Ox/Host/Services/Web/ServiceHandoffSession.swift) reloads the
  same page. It does not clear cookies or switch stores.
- While the login window is open, a separate page checks sign-in roughly every
  second using the same cookies.
- The [sign-in check](../repositories/builtin/web/xiaohongshu.com/actions.js)
  sends `HEAD /notification` and follows redirects. A redirect to `/login` means
  signed out; staying at `/notification` without a redirect means signed in.
  Other results are errors. The check logs HTTP status but does not validate it.
- Ox closes the login window when this check reports signed in, then checks again.

These findings describe the reviewed source. The friend's installed build has
not been checked.

## Explanations that do not fit

- **Closing the window too early:** ignoring HTTP status can cause a false
  sign-in result, but the friend's window never closes.
- **Old cookies left after clearing data:** WebKit fixed a cookie-deletion bug
  in [iOS 26.6](https://webkit.org/blog/18178/webkit-features-for-safari-26-6/).
  It prevents some cookies from being deleted; it does not make new cookies
  disappear. This is a poor explanation for a fresh install.
- **An upgrade losing old sessions:** this is a fresh install, and reload does
  not switch cookie stores.

There is no confirmed iOS-version bug behind this report.

## Possible causes

1. Login does not finish or does not issue a usable session cookie.
2. WebKit rejects the cookie or does not send it on the next request.
3. Xiaohongshu receives the cookie but rejects or replaces the session.
4. The background sign-in checks interfere with login by receiving responses
   that replace shared cookies. This has not been observed.

None of these causes is confirmed.

## Next investigation

Trace one failed login through the first reload:

1. Did the login response issue a session cookie?
2. Did WebKit store it?
3. Did the next request send it?
4. Which response first rejected or replaced the session?
5. Was that request from the login page or the background check?

Record timing, status, redirects, and cookie names and attributes. Never log
cookie values, login codes, authorization headers, or tokens. Keep raw captures
outside the repository.

Existing logs include `getSignInState`, `ServiceAuthSession candidate`,
`ServiceAuthSession verification`, and `Service.authRetention`. Cookie counts
alone cannot show what happened to the session cookie.

Compare fresh logins with background checks enabled and disabled. Also compare
Safari and Ox on the failing phone. Safari success would help narrow the cause,
but would not prove an Ox storage bug. Preserve the working session when testing.
Use Ox's built-in `manage-services` workflow for service changes and verification.

## Work completed

Reviewed source and WebKit documentation. Local Ox hosts had no useful failed
login trace. The friend's phone was not inspected, the failure was not reproduced,
and no fix has been made.

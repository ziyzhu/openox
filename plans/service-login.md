# Remembered service login

Goal: let actions use saved secrets through references, starting with the web `login` action logging in automatically with a saved account. Capture credentials during manual login, verify success, offer to remember them, and reuse them when the intended account is no longer logged in. Secrets are never exposed to Ox as plain text: models, action inputs, results, logs, and service code see only references. The Host resolves a reference only after the secret's permission policy allows it, and only at a Host-owned point that delivers the value to an allowed destination.

Status: the current codebase implements `listSessions`, `login`, account routing, live-page handoffs, access helpers, and selected-session availability checks; these are the foundation, not completed remembered login. Typed secrets, secret references, per-secret permission policies, `context.secret`, and their verification remain unimplemented. Web handlers already receive an empty context (`f58869aa`); `context.secret` will be its only member. API credential UX improvements are follow-up scope; preserve current API and managed OAuth behavior throughout.

## Data model

Extend `SecretEntry` in `secret.index` with optional fields so existing files load unchanged, the index stays at version 1, and the predecessor ignores the new fields:

```swift
nonisolated struct SecretEntry: Codable, Sendable {
    let key: String
    var displayName: String
    let origin: SecretEntryOrigin
    let usePolicy: SecretUsePolicy
    var type: SecretType?
    var serviceID: String?
    var access: [SecretAccess]?
}

nonisolated enum SecretType: String, Codable, Sendable {
    case account
    case apiKey
    case token
}

nonisolated struct SecretAccess: Codable, Sendable {
    let consumer: String
    var origins: [String]
    var policy: ActionPolicy
}
```

- `key` is an opaque stable identifier; service IDs and email addresses are not unique keys. `displayName` is a label, not proof of identity.
- `serviceID` is the credential owner, such as `web:accounts.google.com` or `api:example.com`. For sign-in provider login it is the provider service, never the destination.
- `type` describes stored data, not an authentication mechanism. Values stay in secure credential storage with fixed payloads `{ username, password }`, `{ apiKey }`, and `{ token }`. Preserve the existing `apiKey` field name.
- Every secret is typed; no consumer reads fields beyond these payloads. New entries always carry `type`, and arbitrary-field entry is removed.
- An existing entry whose field names exactly equal one type's payload gains that type on load. Any other entry is untyped and shown as "Needs setup" in Settings, where the user picks a type and maps stored fields to its slots, or deletes it; mapping rewrites the value to the fixed payload and is refused if it drops a field an existing binding requires. Until then its existing bindings keep working, and it cannot be used by reference.
- `publicationOnly` entries never receive `access` rules.
- `SecretBinding` stays as is for providers, API service auth, and repository publication. Managed provider, API, and MCP authorization records stay on their existing storage paths.

## Secret entry

One canonical card collects every secret, in the conversation dock, Settings, and macOS: the `serviceID` icon, one sentence naming the website or service and what Ox will do with it, one grouped block of the type's fixed fields, and two equal-width buttons, "Don't Save" and "Save". `account` shows an editable username and a masked password; `apiKey` and `token` show one masked field. Prefilled values stay fully masked. `ox.secret.add` requires `type` and accepts `serviceID`; Settings adds by picking a type first. The macOS JSON prompt and the Settings field editor are removed.

## Permission policy

Access to each secret is a permission policy. Every resolution of a reference checks it, separately from the action's own Action policy; both must pass.

- `consumer` is a service (`web:example.com`) or an action (`web:example.com:login`). Resolution uses the action rule, then the service rule, then `ask`. An action rule can narrow or widen its service rule.
- `origins` lists exact HTTPS destinations allowed to receive the value. The Host checks them on every resolution.
- `policy` reuses `ActionPolicy` (`ask`, `allow`, `block`). With no matching rule the Host asks; a secret is never allowed by default.
- When both the action and the secret ask, show one approval card covering both, keeping the call one conversation step. "Always approve" writes an `allow` rule for that action and destination only; widening to a service is a Settings choice.
- Rules never cross services: a destination using a sign-in provider's account needs its own rule naming the provider origins.
- Rules are Profile-scoped and never expose a secret to another Profile.
- Settings lists each secret's rules with consumer, origins, and policy; users can change or revoke a rule without deleting the secret. Deleting the secret still requires confirmation.

## Secret references

- A reference is a self-describing input value: `{ $secret: "<key>" }` for the whole secret or `{ $secret: "<key>", field: "<name>" }` for one field, with the key taken from `ox.service.inspect` or `ox.secret.list`. Actions declare nothing; any input field can hold a reference.
- Before dispatch the Host replaces each reference with stand-ins: an object of per-field stand-ins for a whole secret, or a single stand-in for one field. Reference values skip the field's schema type check; the Host validates the reference shape and that the key names a typed secret instead.
- `ox.secret.list` adds `type` and `serviceID` to each item. Permission rules are not exposed to the agent.
- `ox.service.inspect` returns the service's associated secrets as `secrets: [{ key, displayName, type }]`: secrets whose `serviceID` is that service, plus secrets with an access rule naming the service or one of its actions, such as a sign-in provider's login. It exposes metadata only, never values or permission rules.
- The Host never picks a secret on its own. A saved secret is used only when a reference names it.
- Agent guidance in `packages/agent` (the `ox.service.inspect` and `ox.service.invoke` contracts and Evolve's `web-authentication.md`) tells the agent to use an existing associated secret by default. With one matching secret it passes that one; with several it asks the user to pick one by `displayName`; with none it logs in manually. It omits the secret only when the user explicitly asks to log in manually or with a different account.
- The handler receives the field as per-field stand-ins, such as `input.account.username` and `input.account.password`, plus the secret's owning service as plain metadata in `input.account.serviceID`. Stand-ins are opaque strings valid only for the current invocation or login attempt; logging or returning them reveals nothing.
- Only the Host turns a stand-in into a value, after the permission policy and destination check pass:
  - web: `context.secret.type(standIn)` inserts the value at the focused element using native text insertion, after checking the focused element's frame origin. The handler owns focusing, clicking, waiting, and navigation; the Host does not locate or choreograph fields.
  - api: the existing installer `request` replaces stand-ins in `body`, `query`, or `headers` before sending, after checking the destination against the service base URL.
  - mcp and ios: the Host replaces stand-ins in call arguments at dispatch.
- No function returns plain-text values to service code.
- Sensitive action outputs returned as references, so one action can pass a value to another without exposing it, are follow-up scope; the agent would receive them as `{ $secret: "<conversation-scoped id>" }`, each use would ask, and they would live only for the conversation.

## Guardrails

Web values land in the page's DOM, which page-world code, including handlers, can read back; the site needs to read its own fields, so this cannot be blocked in the page. The Host controls every exit to the model:

- Redact resolved values, including base64 and URL-encoded forms, from action results, errors, and logs before they reach the model.
- While an action holds a resolved secret or a login attempt is active, Ox page inspection and screenshots refuse that page.
- Optionally block requests to origins outside the secret's `origins` during the call using `WKContentRuleList`, per service, since some logins load resources from other domains.
- Log attempt IDs, stages, secret keys, bounded consumer and origin identifiers, policy decisions, verification outcomes, durations, and cleanup reasons. Never log values, stand-in resolutions, credential-bearing scripts, cookies, tokens, or sensitive URL components. Clear in-memory values promptly without claiming guaranteed zeroization.

## Service authentication contract

Build on the current account-aware contract: `listSessions` returns logged-in accounts as `{ id, label, url }` descriptors; `login` prepares the login flow and returns `null`. Inspection exposes `access.checkAccess` and `access.requestAccess`; direct invocation remains supported. The Host selects and revalidates the account; handlers check the account on the page only when the page or endpoint might act as a different account.

Change the standard `login` input from a closed empty object to `{ account? }`, where `account` is an `account` secret reference. Without `account`, login is manual even when a matching saved secret exists. Services without auto-login ignore `account` and keep manual login. Services with auto-login own the website-specific workflow: focusing fields, calling `context.secret.type`, advancing username-first and password-next steps, submitting, and handling identity-provider transitions. Do not require `login` to return a declarative workflow.

```js
async invoke(input, context) {
  usernameInput.focus()
  await context.secret.type(input.account.username)
  nextButton.click()
  await waitFor(() => passwordInput)
  passwordInput.focus()
  await context.secret.type(input.account.password)
  submitButton.click()
  return null
}
```

Stand-ins for a login attempt stay valid across full-page navigations within that attempt; the Host resumes the handler on the next page. Define resumption with the existing context-invalidation handling before implementation.

After automatic or manual login, use fresh `listSessions` evidence to establish that the intended account is logged in. Record a verified `accountIdentity` with the secret's access rule when available, scoped to its issuer. Descriptor shape, routing URL, submission, or acknowledgment alone does not prove identity. Resolve ambiguity with the user and distinguish user-confirmed selection from machine-verified identity.

Legacy `getSignInUrl`/`getSignInState` stay unsupported. Protected actions use `requireAuth: true`; discovery and login require `requireAuth: false` and `requireApproval: false`. Preserve pre-dispatch `listSessions` revalidation and Action policies. Do not put secret keys, selections, or values in manifests.

## Web flow

1. Discover logged-in accounts through `listSessions`. Reuse the intended account when available; do not silently substitute another logged-in account.
2. Otherwise invoke `login`, choosing `account` from `ox.service.inspect` by the agent guidance: the one associated `account` secret, the user's pick when several exist, or none for manual login or when the user explicitly declines saved logins. Federated login uses the provider's secret, not a destination-owned copy.
3. When `account` is passed, `login` supports auto-login, and the secret's policy allows it, the handler drives the page and calls `context.secret.type`. The Host checks policy and frame origin on every call. Stop automatic retries after rejection.
4. Without `account`, auto-login support, or an allowed secret, or when a human step is required, show the existing live-page handoff. During handoff offer a native "Fill saved login" action that applies the same policy and origin checks. Capture the login during the active attempt as described in Login capture.
5. Stage captured values in Host memory through pending MFA; discard on rejection, cancellation, timeout, teardown, or process exit. A retry starts new staging.
6. Refresh `listSessions` and verify the intended destination account. Submission, navigation, or acknowledgment alone is not verified login.
7. After verified success with reusable captured values, ask "Remember this login?" in the canonical entry card, naming the credential-owning website and account with the captured values prefilled. Save as a typed `account` secret with an `allow` rule for this `login` action and origin only on acceptance; otherwise discard staged values and keep the browser session. Preserve an old secret until its replacement is verified and accepted.
8. Reuse an existing secret without another remember prompt.

OTP, QR, passkeys, device approval, click-only keypads, and inaccessible forms hand off. If nothing reusable was captured, create no secret and show no prompt. System passkey private keys remain system-owned.

## Sign-in providers

Providers include a company's central login (Google services hop to `accounts.google.com`; Microsoft to `login.microsoftonline.com`; Apple to `appleid.apple.com`), third-party "Continue with Google, Apple, Microsoft, or GitHub", and workplace single sign-on (Okta, Auth0, Entra, company login pages), usually one domain per company.

A provider is an ordinary web service with `listSessions` and `login`, such as `web:accounts.google.com`, and owns its `account` secrets. A hop is two services in sequence; the destination never drives provider pages:

1. The agent passes `account: { $secret: "<provider secret>" }` chosen from the destination's `ox.service.inspect`. That secret has an access rule naming the destination's `login` with the provider's origins.
2. The destination's `login` reads `input.account.serviceID`, clicks the matching provider button or navigates to the provider, and goes no further.
3. When the attempt's page navigates or opens a popup to an origin in that rule, the Host runs the provider service's `login` on that page with the same stand-ins. Only provider code calls `context.secret.type` on provider pages. A redirect alone never authorizes credentials.
4. The provider's `login` handles its own screens: when its `listSessions` already shows the secret's account it types nothing, and on an account chooser it picks the matching account. Consent screens that grant a site access hand off to the user.
5. When the page returns to the destination origin, the Host runs the destination's `listSessions` to verify the intended account. Provider success alone is not destination success. Provider and destination identities are matched separately.
6. Popups belong to the same attempt with the same stand-ins and origin checks. Handoff recovery must not navigate back to the destination while the attempt is on a provider page or a pending challenge.

Without a provider service, or before it is verified, the hop hands off to the user. Capture still works on provider pages that mark `autocomplete` fields and saves the secret under the provider's `serviceID`.

Evolve handles an unknown provider through its normal service workflow:

1. While building or repairing a destination's `login`, it notices the login navigating outside the service domain.
2. It looks for the provider with `ox.service.find` and `ox.service.attach` on that domain.
3. If none exists, it builds a provider service with `listSessions` and `login` using `context.secret.type`, and keeps the destination's `login` to clicking the provider button.
4. It writes provider code from page structure, never asks for or handles passwords, and verifies typing against a saved secret. Workplace single sign-on gets one service per company domain.

## Login capture

Capture relies only on standard `autocomplete` tokens, so it does not depend on forms, submit events, or field guessing:

- The username is the value of a field whose `autocomplete` tokens include `username` or `email`; when both exist, `username` wins. The password is the value of a field whose tokens include `current-password`. Match tokens, so `username webauthn` counts.
- Read values on `change` and `blur` of those fields and on `pagehide`; the last value wins. Keep the username across username-first steps within the attempt.
- Capture succeeds only when a username and a `current-password` value exist in the same attempt. `one-time-code`, `new-password`, and unmarked fields are never read. Sites that do not mark both fields are unsupported for capture; users can still save with `ox.secret.add` and AutoFill.
- Run capture as a document-start user script in the page world, like the existing browser capture script, posting to a native message handler. Values go straight to Swift and never reach service code or the model. Page scripts could post forged values; fresh `listSessions` verification, user confirmation of the save card, and the recorded `accountIdentity` check on later logins contain that to a saved login that fails or is rejected.
- Install capture only for an active login attempt, remove listeners when it ends, and discard values on rejection, cancellation, timeout, teardown, or process exit.

## Edge cases

- Changed password: a rejected auto-login is not retried; hand off, and after verified success capture offers "Update saved login?" while the old secret stays until the replacement is verified.
- Forced password change or locked account after login: hand off; capture never reads `new-password`, so the card asks the user to update the saved login instead of saving silently.
- Duplicate capture: match an existing secret by `serviceID` and username and offer to update it instead of creating another.
- Secret deleted or rule revoked mid-attempt: stand-ins are invalidated immediately, the next `type` fails, and the page hands off.
- Lockout: at most one automatic attempt per secret per login, with a cooldown after rejection; never retry automatically.
- Captcha or unusual-activity pages hand off immediately without retry.
- "Stay signed in" and "Trust this device" stay at the site's default; screens that change device trust hand off.
- Another account already signed in: never sign it out or clear cookies; use the site's account switcher when the provider's `login` supports it, otherwise hand off.
- Two conversations on one site with different accounts: shared cookies mean one login changes the other; pre-dispatch revalidation fails the other conversation cleanly instead of acting as the wrong account.
- Site-remembered username: the handler types only the password; unused stand-ins are ignored.
- Regional or changed provider domains: origins are exact and never wildcards; an unlisted origin blocks the hop and hands off until the user or Evolve adds it to the rule.
- Cross-origin login frames: each frame's own origin must be in the rule, regardless of the top page.
- Redesigned login page: the handler fails and hands off, Evolve repairs the service, and capture still works if the page marks its fields.
- Prompt injection: using a secret on a site without a rule shows the approval card naming the secret, action, and destination origin; "Always approve" stays action- and origin-scoped.
- Background or scheduled work that reaches an `ask` policy fails immediately with a clear error instead of waiting for an unseen approval.
- Declined remember prompt: offer "Never for this site" so manual logins stop prompting.
- Keychain unavailable before first unlock: references fail as "secret unavailable", not as a rejected password.
- Profile export and import exclude secrets; imported rules pointing to missing secrets are dropped.
- Secrets and rules belong to the Host device; `ox.service.inspect` lists only that Host's secrets, and references never cross Hosts.
- Process exit mid-typing: stand-ins expire with the process; a half-filled page is neither saved nor retried on next launch.

## Session scope

Coordinate with `plans/browser.md`: website sessions are shared and Profile isolation is separately planned. A different active account requires account selection or handoff, not silent use or global cookie deletion. Do not promise simultaneous isolated provider sessions in the first implementation.

## API follow-up

Reuse allowed saved secrets through `request` stand-ins. Otherwise render native inputs from the existing API auth configuration and save typed `apiKey`, `token`, or `account` entries. Verify with a service-specific safe authenticated read, never a mutation. After verification, ask "Remember this connection?"; on decline, keep values only for the authorized operation in progress with a bounded lifetime. Keep OAuth's managed authorization, refresh, and revocation path with OpenOx-registered applications.

## Implementation sequence

- [ ] Reproduce current web/API login and inspect credential entry, handoff completion, account detection, permissions, script execution, and output/log exposure with disposable accounts and local fixtures, diagnostics outside Git.
- [x] Remove `session` from the web handler context (`f58869aa`); a real-account Drive check is still pending.
- [ ] Add `type`, `serviceID`, and `access` to `SecretEntry`; type matching entries on load; extend `ox.secret.list`, add associated secrets to `ox.service.inspect`, and require `type` in `ox.secret.add`; verify predecessor compatibility of `secret.index`.
- [ ] Replace the dock card, Settings editor, and macOS prompt with the canonical entry card, and add "Needs setup" field mapping in Settings.
- [ ] Add the permission policy resolution, combined approval card, and Settings rules UI with stable identifiers, localization, accessible labels, and equal outer padding.
- [ ] Add `$secret` reference handling to invocation validation and the protocol schema sources and generated contracts; implement stand-ins and Host resolution for web `context.secret.type` and API `request`.
- [ ] Add redaction, page-inspection lock, and optional origin blocking; prove them with controlled forms before production persistence. Consult current Apple WebKit documentation and keep platform adapters under their apps.
- [ ] Change `login` input to `{ account? }`, implement attempt-scoped stand-ins across navigation, capture, verification, remember prompt, and reuse after expiry. Update Evolve's `web-authentication.md` and representative services together.
- [ ] Add sign-in provider hops: Host detection of provider origins and popups, running the provider's `login` in the attempt, destination verification on return, a `web:accounts.google.com` provider service with Google services' `login` reduced to the hop, and Evolve guidance for unknown providers.
- [ ] Follow-up: API typed inputs and verification, mcp/ios resolution, and sensitive output references.

## Verification and completion

Use E2E coverage, not new unit tests. Exercise load-time typing of exact-match entries, "Needs setup" mapping and deletion with bindings still working, policy resolution (action over service over ask, block over allow, combined approval, always-approve scope, Profile isolation, revoked rules), `login` without `account` staying manual when a matching secret exists, agent choice of a single associated secret, asking the user to pick among several, honoring an explicit request to log in manually, `ox.service.inspect` listing associated and provider-granted secrets without values, malformed references, unknown or untyped keys, wrong-type secrets at resolution, forged and expired stand-ins, wrong-origin typing, capture with `username` and `email` tokens, username-first capture, formless logins, pages missing either token, `one-time-code` fields, forged capture messages, frames, redirects, multi-step and dynamic forms, navigation mid-attempt, MFA, rejection and retry, remember acceptance and decline, expiry, cancellation, concurrent attempts, process termination, saved replacement, same-company and third-party provider hops, provider popups, already-signed-in providers, provider account choosers, consent handoff, origins outside the rule, provider success without destination success, hops without a provider service, manual-only `login`, and reopening the selected account's page. Exercise every case in Edge cases. Check actual model outputs, action results, errors, and logs for values, including encoded forms.

Verify predecessor-written storage with the changed build and changed-build storage with the predecessor. Keep credentials out of Profile export/import according to existing backup behavior. Build iOS and macOS for shared native changes, run protocol and storage checks, and capture simulator screenshots or video for approval cards, handoff, remember prompts, and Settings.

Core scope is done when a saved account secret restores the intended logged-in account through `login` without exposing its value to Ox, every resolution is governed by the secret's permission policy, manual-only services still work, existing secrets and managed credentials remain usable, a different provider account cannot be silently substituted, and unremembered credentials leave no persisted values.

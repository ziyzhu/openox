# Remembered service login

Goal: let actions use saved secrets through references, starting with the web `login` action logging in automatically with a saved account. Capture credentials during manual login, verify success, offer to remember them, and reuse them when the intended account is no longer logged in. Secrets are never exposed to Ox as plain text: models, action inputs, results, and logs see only references. Only the secret's owning service retrieves its value, on its own domain, after the secret's permission policy allows it.

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
    var policy: ActionPolicy
}
```

- `key` is an opaque stable identifier; service IDs and email addresses are not unique keys. `displayName` is a label, not proof of identity.
- `serviceID` is the credential owner, such as `web:accounts.google.com` or `api:example.com`. For sign-in provider login it is the provider service, never the destination. Its service domain is the only place the value can be retrieved.
- `type` describes stored data, not an authentication mechanism. Values stay in secure credential storage with fixed payloads `{ username, password }`, `{ apiKey }`, and `{ token }`. Preserve the existing `apiKey` field name.
- Every secret is typed; no consumer reads fields beyond these payloads. New entries always carry `type`, and arbitrary-field entry is removed.
- An existing entry whose field names exactly equal one type's payload gains that type on load. Any other entry is untyped and shown as "Needs setup" in Settings, where the user picks a type and maps stored fields to its slots, or deletes it; mapping rewrites the value to the fixed payload and is refused if it drops a field an existing binding requires. Until then its existing bindings keep working, and it cannot be used by reference.
- `publicationOnly` entries never receive `access` rules.
- `SecretBinding` stays as is for providers, API service auth, and repository publication. Managed provider, API, and MCP authorization records stay on their existing storage paths.

## Secret entry

One canonical card collects every secret, in the conversation dock, Settings, and macOS: the `serviceID` icon, one sentence naming the website or service and what Ox will do with it, one grouped block of the type's fixed fields, and two equal-width buttons, "Don't Save" and "Save". `account` shows an editable username and a masked password; `apiKey` and `token` show one masked field. Prefilled values stay fully masked. `ox.secret.add` requires `type` and accepts `serviceID`; Settings adds by picking a type first. The macOS JSON prompt and the Settings field editor are removed.

## Permission policy

Access to each secret is a permission policy. Every retrieval checks it, separately from the action's own Action policy; both must pass.

- `consumer` is a service (`web:example.com`) or an action (`web:example.com:login`): the action the agent passed the reference to. Resolution uses the action rule, then the service rule, then `ask`. An action rule can narrow or widen its service rule.
- `policy` reuses `ActionPolicy` (`ask`, `allow`, `block`). With no matching rule the Host asks; a secret is never allowed by default.
- Rules name who may use a secret, not where it may go: the destination is always the owning service's domain.
- When both the action and the secret ask, show one approval card covering both, keeping the call one conversation step. "Always approve" writes an `allow` rule for that action only; widening to a service is a Settings choice.
- A destination using a sign-in provider's account needs its own rule; rules never carry over between consumers.
- Rules are Profile-scoped and never expose a secret to another Profile.
- Settings lists each secret's rules with consumer and policy; users can change or revoke a rule without deleting the secret. Deleting the secret still requires confirmation.

## Secret references

- A reference is a self-describing input value: `{ $secret: "<key>" }` for the whole secret or `{ $secret: "<key>", field: "<name>" }` for one field, with the key taken from `ox.service.inspect` or `ox.secret.list`. Actions declare nothing; any input field can hold a reference.
- The Host validates each reference before dispatch: the key names a typed secret in this Profile and the field exists. Reference values skip the field's schema type check. The Host adds the owner as plain metadata, so the handler receives `{ $secret: "<key>", serviceID: "web:accounts.google.com" }`.
- `ox.secret.list` adds `type` and `serviceID` to each item. Permission rules are not exposed to the agent.
- `ox.service.inspect` returns the service's associated secrets as `secrets: [{ key, displayName, type }]`: secrets whose `serviceID` is that service, plus secrets with an access rule naming the service or one of its actions, such as a sign-in provider's login. It exposes metadata only, never values or permission rules.
- The Host never picks a secret on its own. A saved secret is used only when a reference names it.
- Agent guidance in `packages/agent` (the `ox.service.inspect` and `ox.service.invoke` contracts and Evolve's `web-authentication.md`) tells the agent to use an existing associated secret by default. With one matching secret it passes that one; with several it asks the user to pick one by `displayName`; with none it logs in manually. It omits the secret only when the user explicitly asks to log in manually or with a different account.
- Service code retrieves values with `await context.secret(ref)`, which returns the payload, or one string for a field reference. Web and API handlers both receive `context`; API handlers currently get only `args` and gain the second argument.
- Retrieval succeeds only when all of these hold:
  - `ref` is a reference the agent passed into this invocation or login attempt; service code cannot name other secrets.
  - The calling action belongs to the secret's owning service.
  - For web, the calling frame's origin is within the owning service's domain. For API, the owning service is the API service itself.
  - The permission policy for the consumer allows it, asking when needed.
- mcp and ios have no service code; the Host replaces references in call arguments at dispatch to the owning server or app after the same checks.
- Sensitive action outputs returned as references, so one action can pass a value to another without exposing it, are follow-up scope; the agent would receive them as `{ $secret: "<conversation-scoped id>" }`, each use would ask, and they would live only for the conversation.

## Guardrails

After retrieval the value is in service code, so the Host constrains where it can go and every exit to the model:

- API handlers run in a bare `JSContext` whose only network path is `request`, which is bound to the service `baseUrl`. Verify no other path exists.
- Web values can be sent by page-world code. During an attempt holding a retrieved secret, optionally block requests to origins outside the owning service's domain using `WKContentRuleList`, per service, since some logins load resources from other domains.
- Redact retrieved values, including base64 and URL-encoded forms, from action results, errors, and logs before they reach the model.
- While an action holds a retrieved secret or a login attempt is active, Ox page inspection and screenshots refuse that page.
- Log attempt IDs, stages, secret keys, bounded consumer and origin identifiers, policy decisions, verification outcomes, durations, and cleanup reasons. Never log values, credential-bearing scripts, cookies, tokens, or sensitive URL components. Clear in-memory values promptly without claiming guaranteed zeroization.

## Service authentication contract

Build on the current account-aware contract: `listSessions` returns logged-in accounts as `{ id, label, url }` descriptors; `login` prepares the login flow and returns `null`. Inspection exposes `access.checkAccess` and `access.requestAccess`; direct invocation remains supported. The Host selects and revalidates the account; handlers check the account on the page only when the page or endpoint might act as a different account.

Change the standard `login` input from a closed empty object to `{ account? }`, where `account` is an `account` secret reference. Without `account`, login is manual even when a matching saved secret exists. Services without auto-login ignore `account` and keep manual login. Services with auto-login own the website-specific workflow: retrieving the secret, filling fields however the site needs, advancing username-first and password-next steps, and submitting. Do not require `login` to return a declarative workflow.

```js
async invoke(input, context) {
  if (!input.account) return openLoginDialog()
  const { username, password } = await context.secret(input.account)
  fill(usernameInput, username)
  nextButton.click()
  await waitFor(() => passwordInput)
  fill(passwordInput, password)
  submitButton.click()
  return null
}
```

Multi-step logins (account, Next, password) take two shapes:

- Same page: the password field appears without navigation. The handler waits for it within one invocation.
- New page: the step navigates and the existing context-invalidation handling ends the handler. `login` is written as a step function that inspects the page and performs only the step it shows, so rerunning never repeats a completed step.

The Host drives a step loop for each login attempt. When the page navigates during or after a step and the attempt is unverified, it waits for the load and reruns the same `login` with the same input. It stops when `listSessions` shows the intended account, when the handler returns with no navigation (verify, then hand off on failure), when the page reaches a provider's domain (the provider's `login` continues the loop), or after a bounded step limit (hand off). Each step retrieves again, so ownership, origin, and policy are checked on every page; an `ask` answer holds for the rest of the attempt. References stay valid for the whole attempt. Lockout counts password submissions, not steps.

```js
async invoke(input, context) {
  if (!input.account) return openLoginDialog()
  const { username, password } = await context.secret(input.account)
  const passwordInput = document.querySelector('input[autocomplete~="current-password"]')
  if (passwordInput) {
    fill(passwordInput, password)
    return submit()
  }
  fill(document.querySelector('input[autocomplete~="username"]'), username)
  return next()
}
```

After automatic or manual login, use fresh `listSessions` evidence to establish that the intended account is logged in. Record a verified `accountIdentity` with the secret's access rule when available, scoped to its issuer. Descriptor shape, routing URL, submission, or acknowledgment alone does not prove identity. Resolve ambiguity with the user and distinguish user-confirmed selection from machine-verified identity.

Legacy `getSignInUrl`/`getSignInState` stay unsupported. Protected actions use `requireAuth: true`; discovery and login require `requireAuth: false` and `requireApproval: false`. Preserve pre-dispatch `listSessions` revalidation and Action policies. Do not put secret keys, selections, or values in manifests.

## Web flow

1. Discover logged-in accounts through `listSessions`. Reuse the intended account when available; do not silently substitute another logged-in account.
2. Otherwise invoke `login`, choosing `account` from `ox.service.inspect` by the agent guidance: the one associated `account` secret, the user's pick when several exist, or none for manual login or when the user explicitly declines saved logins. Federated login uses the provider's secret, not a destination-owned copy.
3. When `account` is passed and `login` supports auto-login, the handler calls `context.secret(input.account)` and drives the page. The Host checks ownership, frame origin, and policy at retrieval. Stop automatic retries after rejection.
4. Without `account`, auto-login support, or an allowed secret, or when a human step is required, show the existing live-page handoff. During handoff offer a native "Fill saved login" action that fills the page's `username`/`email` and `current-password` fields after the same ownership, origin, and policy checks. Capture the login during the active attempt as described in Login capture.
5. Stage captured values in Host memory through pending MFA; discard on rejection, cancellation, timeout, teardown, or process exit. A retry starts new staging.
6. Refresh `listSessions` and verify the intended destination account. Submission, navigation, or acknowledgment alone is not verified login.
7. After verified success with reusable captured values, ask "Remember this login?" in the canonical entry card, naming the credential-owning website and account with the captured values prefilled. Save as a typed `account` secret owned by that website's service with an `allow` rule for this `login` action only on acceptance; otherwise discard staged values and keep the browser session. Preserve an old secret until its replacement is verified and accepted.
8. Reuse an existing secret without another remember prompt.

OTP, QR, passkeys, device approval, click-only keypads, and inaccessible forms hand off. If nothing reusable was captured, create no secret and show no prompt. System passkey private keys remain system-owned.

## Sign-in providers

Providers include a company's central login (Google services hop to `accounts.google.com`; Microsoft to `login.microsoftonline.com`; Apple to `appleid.apple.com`), third-party "Continue with Google, Apple, Microsoft, or GitHub", and workplace single sign-on (Okta, Auth0, Entra, company login pages), usually one domain per company.

A provider is an ordinary web service with `listSessions` and `login`, such as `web:accounts.google.com`, and owns its `account` secrets. A hop is two services in sequence; the destination never handles provider values:

1. The agent passes `account: { $secret: "<provider secret>" }` chosen from the destination's `ox.service.inspect`. That secret has an access rule naming the destination's `login`.
2. The destination's `login` reads `input.account.serviceID`, clicks the matching provider button or navigates to the provider, and goes no further. It cannot retrieve the value, because it is not the owning service.
3. When the attempt's page navigates or opens a popup to the owning provider's domain, the Host runs the provider service's `login` on that page with the same input. Only provider code on the provider's domain can retrieve the value. A redirect alone never authorizes credentials.
4. The provider's `login` handles its own screens: when its `listSessions` already shows the secret's account it retrieves nothing, and on an account chooser it picks the matching account. Consent screens that grant a site access hand off to the user.
5. When the page returns to the destination origin, the Host runs the destination's `listSessions` to verify the intended account. Provider success alone is not destination success. Provider and destination identities are matched separately.
6. Popups belong to the same attempt with the same input and checks. Handoff recovery must not navigate back to the destination while the attempt is on a provider page or a pending challenge.

Without a provider service, or before it is verified, the hop hands off to the user. Capture still works on provider pages that mark `autocomplete` fields and saves the secret under the provider's `serviceID`.

Evolve handles an unknown provider through its normal service workflow:

1. While building or repairing a destination's `login`, it notices the login navigating outside the service domain.
2. It looks for the provider with `ox.service.find` and `ox.service.attach` on that domain.
3. If none exists, it builds a provider service with `listSessions` and `login` using `context.secret`, and keeps the destination's `login` to clicking the provider button.
4. It writes provider code from page structure, never asks for or handles passwords, and verifies filling against a saved secret. Workplace single sign-on gets one service per company domain.

## Login capture

Capture relies only on standard `autocomplete` tokens, so it does not depend on forms, submit events, or field guessing:

- The username is the value of a field whose `autocomplete` tokens include `username` or `email`; when both exist, `username` wins. The password is the value of a field whose tokens include `current-password`. Match tokens, so `username webauthn` counts.
- Read values on `input`, `change`, and `blur` of those fields and on `pagehide`, posting `{ kind, value }` to native; the last value wins. Clicking Next blurs the field first, and `pagehide` covers immediate navigation. AutoFill fires the same events.
- Staging lives in Swift, keyed by the login attempt rather than the page, so values survive navigation between steps. The capture script is reinjected into every page and frame the attempt loads.
- The username comes from, in order: a username field on the password step (often hidden or read-only for password managers), the value staged from an earlier step, then the verified `listSessions` account's `label` or `id` for sites that remember the username; the last is shown editable on the save card and never supplies a password.
- A username and password pair only when both were captured within the same service's domain in the same attempt; the secret belongs to that service, which for a hop is the provider.
- Capture succeeds only when a `current-password` value exists in the attempt with a username from the sources above. `one-time-code`, `new-password`, and unmarked fields are never read. Sites that do not mark `current-password` are unsupported for capture; users can still save with `ox.secret.add` and AutoFill.
- Run capture as a document-start user script in the page world, like the existing browser capture script, posting to a native message handler. Values go straight to Swift and never reach service code or the model. Page scripts could post forged values; fresh `listSessions` verification, user confirmation of the save card, and the recorded `accountIdentity` check on later logins contain that to a saved login that fails or is rejected.
- Install capture only for an active login attempt, remove listeners when it ends, and discard values on rejection, cancellation, timeout, teardown, or process exit.

## Edge cases

- Changed password: a rejected auto-login is not retried; hand off, and after verified success capture offers "Update saved login?" while the old secret stays until the replacement is verified.
- Forced password change or locked account after login: hand off; capture never reads `new-password`, so the card asks the user to update the saved login instead of saving silently.
- Duplicate capture: match an existing secret by `serviceID` and username and offer to update it instead of creating another.
- Secret deleted or rule revoked mid-attempt: the attempt's references are invalidated immediately, the next retrieval fails, and the page hands off.
- Lockout: at most one automatic attempt per secret per login, with a cooldown after rejection; never retry automatically.
- Captcha or unusual-activity pages hand off immediately without retry.
- "Stay signed in" and "Trust this device" stay at the site's default; screens that change device trust hand off.
- Another account already signed in: never sign it out or clear cookies; use the site's account switcher when the provider's `login` supports it, otherwise hand off.
- Two conversations on one site with different accounts: shared cookies mean one login changes the other; pre-dispatch revalidation fails the other conversation cleanly instead of acting as the wrong account.
- Site-remembered username: the handler fills only the password, using a field reference or ignoring the unused field.
- Provider login on another domain (regional or moved): retrieval is refused outside the owning service's domain, so the hop hands off until the provider service covers that domain.
- Cross-origin login frames: the frame's own origin must be within the owning service's domain, regardless of the top page.
- Redesigned login page: the handler fails and hands off, Evolve repairs the service, and capture still works if the page marks its fields.
- Prompt injection: using a secret without a rule shows the approval card naming the secret, the consumer action, and the owning service; "Always approve" stays action-scoped.
- Service code naming a secret it was not passed: retrieval is refused.
- Background or scheduled work that reaches an `ask` policy fails immediately with a clear error instead of waiting for an unseen approval.
- Declined remember prompt: offer "Never for this site" so manual logins stop prompting.
- Keychain unavailable before first unlock: retrieval fails as "secret unavailable", not as a rejected password.
- Profile export and import exclude secrets; imported rules pointing to missing secrets are dropped.
- Secrets and rules belong to the Host device; `ox.service.inspect` lists only that Host's secrets, and references never cross Hosts.
- Process exit mid-login: references expire with the attempt; a half-filled page is neither saved nor retried on next launch.

## Session scope

Coordinate with `plans/browser.md`: website sessions are shared and Profile isolation is separately planned. A different active account requires account selection or handoff, not silent use or global cookie deletion. Do not promise simultaneous isolated provider sessions in the first implementation.

## API follow-up

Reuse allowed saved secrets through `context.secret` in API handlers, sent only through `request`. Otherwise render native inputs from the existing API auth configuration and save typed `apiKey`, `token`, or `account` entries. Verify with a service-specific safe authenticated read, never a mutation. After verification, ask "Remember this connection?"; on decline, keep values only for the authorized operation in progress with a bounded lifetime. Keep OAuth's managed authorization, refresh, and revocation path with OpenOx-registered applications.

## Implementation sequence

- [ ] Reproduce current web/API login and inspect credential entry, handoff completion, account detection, permissions, script execution, and output/log exposure with disposable accounts and local fixtures, diagnostics outside Git.
- [x] Remove `session` from the web handler context (`f58869aa`); a real-account Drive check is still pending.
- [ ] Add `type`, `serviceID`, and `access` to `SecretEntry`; type matching entries on load; extend `ox.secret.list`, add associated secrets to `ox.service.inspect`, and require `type` in `ox.secret.add`; verify predecessor compatibility of `secret.index`.
- [ ] Replace the dock card, Settings editor, and macOS prompt with the canonical entry card, and add "Needs setup" field mapping in Settings.
- [ ] Add the permission policy resolution, combined approval card, and Settings rules UI with stable identifiers, localization, accessible labels, and equal outer padding.
- [ ] Add `$secret` reference validation to invocation and the protocol schema sources and generated contracts; implement `context.secret` with ownership, origin, and policy checks for web and API handlers.
- [ ] Add redaction, page-inspection lock, and optional origin blocking; confirm API handlers have no network path besides `request`. Prove them with controlled forms before production persistence. Consult current Apple WebKit documentation and keep platform adapters under their apps.
- [ ] Change `login` input to `{ account? }`, keep references valid across navigation within an attempt, and implement capture, verification, remember prompt, and reuse after expiry. Update Evolve's `web-authentication.md` and representative services together.
- [ ] Add sign-in provider hops: Host detection of provider domains and popups, running the provider's `login` in the attempt, destination verification on return, a `web:accounts.google.com` provider service with Google services' `login` reduced to the hop, and Evolve guidance for unknown providers.
- [ ] Follow-up: API typed inputs and verification, mcp/ios resolution, and sensitive output references.

## Verification and completion

Use E2E coverage, not new unit tests. Exercise load-time typing of exact-match entries, "Needs setup" mapping and deletion with bindings still working, policy resolution (action over service over ask, block over allow, combined approval, always-approve scope, Profile isolation, revoked rules), `login` without `account` staying manual when a matching secret exists, agent choice of a single associated secret, asking the user to pick among several, honoring an explicit request to log in manually, `ox.service.inspect` listing associated and provider-granted secrets without values, malformed references, unknown or untyped keys, wrong-type secrets, retrieval by a non-owning service, retrieval from a frame outside the owner's domain, retrieval of a secret not passed in, sending a retrieved value to another origin, capture with `username` and `email` tokens, username-first capture across same-page and full-page steps, hidden username fields on the password step, remembered usernames falling back to the verified account, username and password from different services not pairing, the login step loop stopping on verification, no navigation, provider handoff, and the step limit, formless logins, pages missing either token, `one-time-code` fields, forged capture messages, frames, redirects, multi-step and dynamic forms, navigation mid-attempt, MFA, rejection and retry, remember acceptance and decline, expiry, cancellation, concurrent attempts, process termination, saved replacement, same-company and third-party provider hops, provider popups, already-signed-in providers, provider account choosers, consent handoff, provider success without destination success, hops without a provider service, manual-only `login`, and reopening the selected account's page. Exercise every case in Edge cases. Check actual model outputs, action results, errors, and logs for values, including encoded forms.

Verify predecessor-written storage with the changed build and changed-build storage with the predecessor. Keep credentials out of Profile export/import according to existing backup behavior. Build iOS and macOS for shared native changes, run protocol and storage checks, and capture simulator screenshots or video for approval cards, handoff, remember prompts, and Settings.

Core scope is done when a saved account secret restores the intended logged-in account through `login` without exposing its value to the model or any non-owning service, every retrieval is governed by the secret's permission policy, manual-only services still work, existing secrets and managed credentials remain usable, a different provider account cannot be silently substituted, and unremembered credentials leave no persisted values.

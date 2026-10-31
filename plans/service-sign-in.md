# Remembered service sign-in

Goal: capture or collect credentials during service sign-in, verify success, offer to remember them, and reuse the selected account on later sign-ins. Hosts own credential handling, permissions, sessions, verification, and persistence. Users enter values only; Ox defines credential fields. Models and service code receive status and references, never credential values.

Status: design agreed in conversation; implementation and verification have not started. Extend existing secrets, bindings, sign-in handoffs, and API authorization rather than building a separate authentication system.

## Data model

Extend existing secret metadata with:
- `key`: opaque stable identifier; service IDs and email addresses are not unique secret keys.
- `serviceID`: credential owner, such as `web:google.com` or `api:example.com`.
- `displayName`: human-readable account label; not proof of identity.
- `type`: `password`, `apiKey`, `bearerToken`, or `basicAuth`.
- Values remain separately stored in secure credential storage. Fixed payloads are `{ username, password }`, `{ key }`, `{ token }`, and `{ username, password }`, respectively.

Extend existing bindings to express:
- `serviceID`: destination service.
- `authServiceID`: service performing authentication; equal to `serviceID` for direct sign-in.
- `secretKey?`: selected credential reference; absent when there is nothing reusable to save.
- `accountIdentity?`: verified account identifier when available, scoped to its issuer/service.
- `displayName?`: account label, including for connections without a secret.
- `allowedOrigins`: exact HTTPS credential destinations, enforced by the Host.
- `configurationFingerprint`: detects changes that invalidate credential authorization.

Keep service bindings in the existing Host credential index (`secret.index`), not repository manifests. Preserve existing provider and publication consumers and their policies. Adapt existing storage field names where possible rather than mechanically replacing all consumers. A secret can serve several destination bindings; each destination selects a specific provider account. Initially keep one selected account per destination; switching replaces the selection without deleting other saved credentials.

Use an in-memory sign-in attempt with attempt ID, destination `serviceID`, current `authServiceID`, selected secret reference, optional typed staged values, and explicit state. Associate staged values with the verified document/frame origin and authentication step, not merely the destination service. Keep browser session data in existing website storage; a secret reference does not identify or isolate a browser session.

## Service authentication contract

Preserve the existing API `auth` object and its configuration. Add optional web `auth` declarations as a flat array without method IDs or a `methods` wrapper, for example:

```json
{
  "auth": [
    { "type": "password" },
    { "type": "federated", "authServiceID": "web:google.com" },
    { "type": "otp" },
    { "type": "qr" },
    { "type": "passkey" }
  ]
}
```

Authentication methods describe supported flows; secret types describe reusable credential values. Do not put account selections, secret references, or values in manifests. Missing web declarations preserve existing manual sign-in behavior; an explicit empty array means no authentication methods are declared.

Retain `getSignInUrl`, `getSignInState`, and action `requireAuth` behavior. Add optional account identity evidence without breaking the existing closed `{ signedIn: boolean }` contract; select an additive/versioned contract during implementation. Define how login fields and steps are identified through existing web execution facilities. Service code may describe targets but cannot resolve secrets. Declarations and redirects alone never grant access to a provider's credentials.

## Web flow

1. Reuse the browser session when authenticated access and the required account are established. A boolean signed-in detector alone cannot establish account identity.
2. Otherwise resolve the actual authentication service, selected method, and bound account. Managed sign-in uses the provider's service and credentials, not the destination's password entry.
3. With an authorized saved secret, the Host validates the active document/frame origin immediately before filling. Resolve ambiguous account selection or unfamiliar credential destinations with the user. Stop automatic retries after rejection.
4. Without usable credentials, show the existing website sign-in handoff. Capture relevant username/password inputs during this active attempt, before submission clears them. Support username-first and password-next pages, dynamic forms, and observable autofill. Do not collect unrelated fields, OTPs, recovery codes, or QR payloads as passwords.
5. Stage captured values in Host memory. Retain them through pending MFA, but discard on rejected authentication, cancellation, timeout, teardown, or process exit. A retry begins new staging; do not carry rejected values into it.
6. Verify authenticated access and account identity where reliable evidence exists. Ask the user when identity remains ambiguous; record user-confirmed selection distinctly from machine-verified identity. Submission, navigation, or acknowledgment alone is not verified sign-in.
7. After verified success with reusable captured values, ask “Remember this sign-in?” Identify the credential-owning website and account. Save and bind only on acceptance; otherwise discard staged values and retain the browser session. Preserve an old saved credential until replacement succeeds and is accepted.
8. For an existing saved credential, reuse it without another remember prompt. An explicit account change updates the destination selection only after successful verification/confirmation.

OTP, QR, passkeys, device approval, and inaccessible forms hand off when necessary. If nothing reusable was captured, create no secret and show no credential-saving prompt. System passkey private keys remain system-owned. Identity-provider success is not sufficient proof that the destination login completed.

## Session scope and credential exposure

Coordinate with `plans/browser.md`: current website sessions are shared, and Profile isolation is separately planned. Establish credential/binding scope and Profile access rules before changing persistence; do not silently expose remembered credentials across Profiles. Session isolation and multiple concurrent accounts are not delivered by account bindings alone.

Verify the destination account before dependent work when evidence exists. A different active account requires account selection or handoff, not silent use or global cookie deletion. Do not promise simultaneous isolated provider sessions in the first implementation.

Use Host-owned capture and filling, with frame/document provenance and lifecycle cleanup. Inspect arbitrary script execution, DOM results, screenshots, network diagnostics, and error paths for credential exposure. An isolated capture script alone does not prevent page scripts from reading their own form fields. Restrict model/service inspection of credential-bearing documents during sign-in and verify the chosen enforcement through E2E tests; do not rely on redaction alone.

Log attempt IDs, stages, bounded service/origin identifiers, verification outcomes, durations, and cleanup reasons. Never log values, credential-bearing scripts, cookies, tokens, or sensitive URL components. Clear in-memory references promptly without claiming guaranteed zeroization of managed strings.

## API flow

Reuse authorized saved credentials. Otherwise render native inputs derived from the existing API auth configuration: key, token, or username/password. Remove user-authored JSON and arbitrary field naming from service credential entry; audit other secret consumers before replacing their editors.

Stage values and inject them through existing Host request authorization. Verify using a service-specific safe authenticated read; a public success response is insufficient. Do not use a mutation as a credential probe. A rejection discards staging; network failure or ambiguous authorization leaves verification unresolved, with retry/cancel and bounded expiry.

After verification, ask “Remember this connection?” Save on acceptance. On decline, retain credentials only for the explicitly authorized operation in progress, then discard. Define that operation's lifetime so an attachment or background schedule cannot retain ephemeral credentials indefinitely. Refuse persistence-dependent background work until remembered credentials are available.

Keep OAuth's managed authorization, token storage, refresh, and revocation path. Use OpenOx-registered OAuth applications. Authorizing an OAuth connection includes its token retention; do not treat managed tokens as user-entered JSON or capture identity-provider passwords from external authorization sessions.

## Implementation sequence

- [ ] Reproduce current web/API sign-in and inspect credential entry, handoff completion, global website data, account detection, permissions, script execution, and output/log exposure. Use disposable accounts and controlled local fixtures with diagnostics outside Git.
- [ ] Settle Profile scope, additive identity evidence, web login-step targets, and manifest compatibility. Update protocol schema sources, native validation, generated contracts, bundled authoring guidance, and representative services together.
- [ ] Prove Host capture/fill and cleanup with controlled forms before changing production credential persistence. Consult current Apple WebKit documentation and keep platform adapters under their respective apps.
- [ ] Extend typed metadata and existing bindings. Migrate legacy JSON credentials through existing storage owners; preserve legacy provider, publication, API, and OAuth behavior. Unknown legacy shapes must not be guessed or discarded.
- [ ] Complete direct web capture → verification → remember choice → saved reuse after session expiry, including safe replacement and cancellation.
- [ ] Add provider resolution, multiple saved accounts, per-destination selection, and mismatch handling. Use `authServiceID` consistently in manifests, attempts, and bindings.
- [ ] Complete API typed inputs, authenticated verification, remember choice, and ephemeral-operation cleanup.
- [ ] Update settings to show saved accounts and connected services, select/replace credentials, and forget credentials with destructive-action confirmation. Add stable control identifiers, localization, accessible labels, and equal outer padding.

## Verification and completion

Use E2E coverage, not new unit tests. Exercise direct and multi-step login, autofill, dynamic forms, redirects/popups/frames, wrong-origin filling, forged capture messages, MFA, rejection/retry, remember acceptance/decline, expiry, cancellation, concurrent attempts, process termination, saved replacement, shared-provider accounts, session/account mismatch, and connections with no secret. Check actual model/service outputs and logs for credential values.

Exercise each API credential type, public-endpoint false positives, invalid credentials, forbidden responses, network failure, safe verification, redirects, configuration changes, OAuth refresh/revocation, and ephemeral credential expiry. Confirm sign-in permission does not authorize unrelated service mutations.

Verify predecessor-written storage with the changed build and changed-build storage with the predecessor. Report actual upgrade/downgrade behavior and unresolved incompatibilities before release. Keep credentials out of Profile export/import according to existing backup behavior; verify it rather than assuming new metadata is excluded.

Build both iOS and macOS for shared native changes and run applicable protocol/storage checks. Capture simulator screenshots or video for sign-in handoff, account choice, remember prompts, API inputs, and settings. Report LOC delta, file tree diff, call stack diff, cyclomatic complexity, and performance implications for implementation reviews. Limit capture work to active attempts and remove observers/tasks when they end.

Done when the selected account can be reused after session expiry, a different provider account cannot be silently substituted, unsuccessful/unremembered credentials leave no persisted values, interactive methods still complete through handoff, and existing services and stored connections remain usable.

# Remembered service login

Goal: establish an account-type secret and extend the existing web `login` flow to optionally log in automatically using authorized saved credentials. Capture credentials during manual login, verify success, offer to remember them, and reuse them when the intended account is no longer logged in. Hosts own credential handling, permissions, verification, and persistence. Users enter values only; Ox defines credential fields. Models and service code receive status and references, never credential values.

Status: uncommitted WIP introduces `listSessions`, `login`, account routing, and live-page handoffs; it is the foundation, not completed remembered login. Account secrets, optional auto-login support, and their verification remain unimplemented. Extend existing secrets, bindings, and login orchestration rather than building a separate authentication system. API credential UX improvements are follow-up scope; preserve current API and managed OAuth behavior throughout.

## Data model

Extend existing secret metadata with:
- `key`: opaque stable identifier; service IDs and email addresses are not unique secret keys.
- `serviceID`: credential owner, such as `web:google.com` or `api:example.com`.
- `displayName`: human-readable account label; not proof of identity.
- `type`: `account`, `apiKey`, or `token` for typed entries.
- Values remain separately stored in secure credential storage. Fixed payloads are `{ username, password }`, `{ apiKey }`, and `{ token }`, respectively. Preserve the existing `apiKey` field name.

Secret types describe stored data, not authentication mechanisms. An `account` can support website login or HTTP Basic through separately authorized bindings. API keys may be sent in headers, query parameters, or Bearer authorization according to consumer configuration; token transport does not change the stored type. Matching types never grant cross-consumer access.

Existing entries can contain arbitrary nonempty flat string dictionaries. Preserve them and their consumers without guessing types, renaming fields, or dropping extra fields. Whether these remain untyped or receive an explicit custom type is deferred; neither option blocks adding account secrets. Untyped/custom entries are not eligible for automatic website filling. Do not require a wholesale store conversion or replace the general secret editor to deliver auto-login.

Keep managed provider, API, and MCP authorization records on their existing storage paths, including managed keys, access/refresh tokens, expiry, scopes, identity, and client-registration data. They are not static user-entered token secrets. Preserve legacy migration owners and publication-only policy independently of secret type.

Extend existing bindings to express:
- `serviceID`: destination service.
- `authServiceID`: service performing authentication; equal to `serviceID` for direct login.
- `secretKey?`: selected credential reference; absent when there is nothing reusable to save.
- `accountIdentity?`: verified account identifier when available, scoped to its issuer/service.
- `displayName?`: account label, including for connections without a secret.
- `allowedOrigins`: exact HTTPS credential destinations, enforced by the Host.
- `configurationFingerprint`: detects changes that invalidate credential authorization.

Keep service bindings in the existing Host credential index (`secret.index`), not repository manifests. Preserve existing provider and publication consumers and their policies. Adapt existing storage field names where possible rather than mechanically replacing all consumers. A secret can serve several destination bindings; each destination selects a specific provider account. Initially keep one selected account per destination; switching replaces the selection without deleting other saved credentials.

Use an in-memory login attempt with attempt ID, destination `serviceID`, current `authServiceID`, selected secret reference, optional typed staged values, and explicit state. Associate staged values with the verified document/frame origin and authentication step, not merely the destination service. A session means a logged-in account. A saved account secret can exist while its account is logged out, and a logged-in account can exist without a saved secret. Keep cookies and other website data in existing website storage; neither a secret reference nor a session ID creates an isolated website-data store.

## Service authentication contract

Build on the WIP account-aware contract: `listSessions` returns logged-in accounts as `{ id, label, url }` descriptors; `login` prepares the login flow and returns `null`. The Host currently presents the prepared live page for manual interaction. Dismissal acknowledges the handoff, not authenticated success.

Extend `login` and its Host orchestration with optional auto-login support, not a separate auto-login action. Services without that support retain manual login. Define the additive contract for describing username/password field targets, document/frame provenance, and progression through single-page and username-first/password-next flows before implementation. Service code describes targets and steps; the Host selects and authorizes the account secret, validates origins, resolves values, and fills them. Never pass credentials in action inputs, results, or the service-visible `{ session }` context. No new web `auth` method array is required for this scope.

After automatic or manual login, use fresh `listSessions` evidence to establish that the intended account is logged in. Define stable account identification and the evidence required to match a restored account to its binding. Descriptor shape, routing URL, submission, or user acknowledgment alone does not prove that identity or that subsequent actions execute as that account. Resolve ambiguity with the user and distinguish user-confirmed selection from machine-verified identity.

The WIP disallows combining `listSessions`/`login` with legacy authentication actions or `requireAuth` in one service. Preserve `getSignInUrl`, `getSignInState`, and `requireAuth` for legacy services without changing their closed contracts. Settle Host enforcement of selected-account access for account-aware actions before dependent work; removing `requireAuth` must not silently permit execution as another account. Carry account routing consistently through invocation and live-page presentation.

Do not put saved account selections, secret references, or credential values in manifests. Declarations, descriptors, and redirects alone never authorize access to credentials. Preserve the existing API `auth` object and configuration.

## Web flow

1. Discover logged-in accounts through `listSessions`. Reuse the intended account when available and establish that dependent actions execute as that account; do not silently substitute another logged-in account.
2. Otherwise invoke `login` to prepare the flow and resolve the actual authentication service and bound account. Federated login uses the provider's service and credentials, not the destination's password entry.
3. When `login` supports auto-login and an authorized saved account secret is available, the Host validates the active document/frame origin immediately before filling and advances the described steps. Resolve ambiguous account selection or unfamiliar credential destinations with the user. Stop automatic retries after rejection.
4. Without optional auto-login support or usable credentials, or when a human step is required, show the existing live-page login handoff. Capture relevant username/password inputs during this active attempt, before submission clears them. Support username-first and password-next pages, dynamic forms, and observable autofill. Do not collect unrelated fields, OTPs, recovery codes, or QR payloads as passwords.
5. Stage captured values in Host memory. Retain them through pending MFA, but discard on rejected authentication, cancellation, timeout, teardown, or process exit. A retry begins new staging; do not carry rejected values into it.
6. Refresh `listSessions` and verify that the intended destination account is logged in, using reliable account identity evidence. Ask the user when identity remains ambiguous; record user-confirmed selection distinctly from machine-verified identity. Submission, navigation, or acknowledgment alone is not verified login.
7. After verified success with reusable captured values, ask “Remember this login?” Identify the credential-owning website and account. Save and bind only on acceptance; otherwise discard staged values and retain the browser session. Preserve an old saved credential until replacement succeeds and is accepted.
8. For an existing saved credential, reuse it without another remember prompt. An explicit account change updates the destination selection only after successful verification/confirmation.

OTP, QR, passkeys, device approval, and inaccessible forms hand off when necessary. If nothing reusable was captured, create no secret and show no credential-saving prompt. System passkey private keys remain system-owned. Identity-provider success is not sufficient proof that the destination login completed.

## Session scope and credential exposure

Coordinate with `plans/browser.md`: current website sessions are shared, and Profile isolation is separately planned. Establish credential/binding scope and Profile access rules before changing persistence; do not silently expose remembered credentials across Profiles. Session isolation and multiple concurrent accounts are not delivered by account bindings alone.

Verify the destination account before dependent work when evidence exists. A different active account requires account selection or handoff, not silent use or global cookie deletion. Do not promise simultaneous isolated provider sessions in the first implementation.

Use Host-owned capture and filling, with frame/document provenance and lifecycle cleanup. Inspect arbitrary script execution, DOM results, screenshots, network diagnostics, and error paths for credential exposure. An isolated capture script alone does not prevent page scripts from reading their own form fields. Restrict model/service inspection of credential-bearing documents during login and verify the chosen enforcement through E2E tests; do not rely on redaction alone.

Log attempt IDs, stages, bounded service/origin identifiers, verification outcomes, durations, and cleanup reasons. Never log values, credential-bearing scripts, cookies, tokens, or sensitive URL components. Clear in-memory references promptly without claiming guaranteed zeroization of managed strings.

## API follow-up

Reuse authorized saved credentials. Otherwise render native inputs derived from the existing API auth configuration: key, token, or username/password. Use fixed `apiKey`, `token`, or `account` payloads for new typed service entry. Preserve existing arbitrary-field secrets and the general editor; do not replace other consumers' editors as part of auto-login.

Stage values and inject them through existing Host request authorization. Verify using a service-specific safe authenticated read; a public success response is insufficient. Do not use a mutation as a credential probe. A rejection discards staging; network failure or ambiguous authorization leaves verification unresolved, with retry/cancel and bounded expiry.

After verification, ask “Remember this connection?” Save on acceptance. On decline, retain credentials only for the explicitly authorized operation in progress, then discard. Define that operation's lifetime so an attachment or background schedule cannot retain ephemeral credentials indefinitely. Refuse persistence-dependent background work until remembered credentials are available.

Keep OAuth's managed authorization, token storage, refresh, and revocation path. Use OpenOx-registered OAuth applications. Authorizing an OAuth connection includes its token retention; do not treat managed tokens as user-entered JSON or capture identity-provider passwords from external authorization sessions.

## Implementation sequence

- [ ] Reproduce current web/API login and inspect credential entry, handoff completion, global website data, account detection, permissions, script execution, and output/log exposure. Use disposable accounts and controlled local fixtures with diagnostics outside Git.
- [ ] Settle Profile scope, stable account identity from `listSessions`, selected-account enforcement, optional `login` field/step support, and legacy compatibility. Finish consistent account routing through invocation and live-page presentation. Update protocol schema sources, native validation, generated contracts, bundled authoring guidance, and representative services together.
- [ ] Prove Host capture/fill and cleanup with controlled forms before changing production credential persistence. Consult current Apple WebKit documentation and keep platform adapters under their respective apps.
- [ ] Add typed `account` secrets and extend existing bindings without requiring conversion of all existing entries. Preserve `{ apiKey }`, `{ token }`, arbitrary flat-string entries, existing consumer policies, and separate managed authorization records. Use existing migration owners for any necessary storage changes; unknown legacy shapes must not be guessed or discarded.
- [ ] Extend `login` with optional Host-controlled auto-login and manual fallback. Complete direct web capture → fresh `listSessions` verification → remember choice → saved reuse after account expiry, including safe replacement and cancellation.
- [ ] Add provider resolution, multiple saved accounts, per-destination selection, and mismatch handling. Use `authServiceID` consistently in manifests, attempts, and bindings.
- [ ] Follow-up: complete API typed inputs, authenticated verification, remember choice, and ephemeral-operation cleanup; do not block web auto-login on this work.
- [ ] Update settings to show saved accounts and connected services, select/replace credentials, and forget credentials with destructive-action confirmation. Add stable control identifiers, localization, accessible labels, and equal outer padding.

## Verification and completion

Use E2E coverage, not new unit tests. Exercise direct and multi-step login, autofill, dynamic forms, redirects/popups/frames, wrong-origin filling, forged capture messages, MFA, rejection/retry, remember acceptance/decline, expiry, cancellation, concurrent attempts, process termination, saved replacement, shared-provider accounts, session/account mismatch, and connections with no secret. Exercise stale or forged session descriptors, stable account matching after expiry, account changes through shared cookies, manual-only `login`, and reopening the selected account's live page. Check actual model/service outputs and logs for credential values.

For the API follow-up, exercise each API credential type, public-endpoint false positives, invalid credentials, forbidden responses, network failure, safe verification, redirects, configuration changes, OAuth refresh/revocation, and ephemeral credential expiry. Confirm login permission does not authorize unrelated service mutations.

Verify predecessor-written storage with the changed build and changed-build storage with the predecessor. Report actual upgrade/downgrade behavior and unresolved incompatibilities before release. Keep credentials out of Profile export/import according to existing backup behavior; verify it rather than assuming new metadata is excluded.

Build both iOS and macOS for shared native changes and run applicable protocol/storage checks. Capture simulator screenshots or video for login handoff, account choice, remember prompts, API inputs, and settings. Report LOC delta, file tree diff, call stack diff, cyclomatic complexity, and performance implications for implementation reviews. Limit capture work to active attempts and remove observers/tasks when they end.

Core scope is done when an account secret can restore the intended logged-in account through optional auto-login in `login`, manual-only services still work, arbitrary existing secrets and managed credentials remain usable, the selected account can be reused after expiry, a different provider account cannot be silently substituted, unsuccessful/unremembered credentials leave no persisted values, interactive methods still complete through handoff, and existing services and stored connections remain usable.

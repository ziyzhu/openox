# Piping credentials into secrets

Status: proposal. Nothing implemented.

Let services with custom sign-in (SMS code, email code, token refresh) work without new auth types. The model writes the script that moves a credential from an action result into a secret, but never reads the value. Hinge is the motivating case: SMS sign-in returns a bearer token, refresh replaces it and invalidates the old one, and every request needs the token plus device headers.

## Principle

One general rule in the runtime, everything else in skills and service code.

- A secret is a value addressed by a reference `{ $secret: key }`.
- Ox substitutes the value at the last moment, only for the owning service.
- Ox removes known secret values from anything model-visible or recorded.

No runtime knowledge of SMS, OTP, 2FA, refresh, or any service's auth shape.

## Changes

### 1. `ox.secret.add` accepts `value`

```js
await ox.secret.add({ purpose, key, type, serviceID, value })
```

- Without `value`: unchanged native card.
- With `value`: save directly under normal Action policy (`ox.secret.add` approval), no card. `value` matches the type's fields (`{ token }`, `{ apiKey }`, `{ username, password }`).
- Replacing an existing key is one Keychain write, so refresh is the same call.
- The recorded invocation stores `value` as `[redacted]`.

Today: `SecretFunctions.swift` builds a `SecretEntrySpec` and always prompts.

### 2. References resolve anywhere in an API request

A handler can put a reference in headers, query, or JSON body:

```js
await request({ path: "user/v3", headers: { Authorization: { $secret: "hinge", field: "token" } } })
```

- The reference resolves to the whole stored field. A scheme such as `Bearer ` is stored with the value, so references need no new fields.
- Resolution reuses `SecretAttempt.retrieve`: owner must equal the calling service, permission rules apply.
- A header set through a reference is exempt from the reserved-header list. Literal values are still rejected for `Authorization` and other reserved names.
- Resolved values are added to the attempt's redaction set.

Today: references resolve only in action input, and handlers fetch values through `context.secret(ref)` (`APIService.swift`, `$retrieve`). Request headers reject `Authorization` outright.

### 3. Redact known secrets from records and output

When a secret is saved or resolved during an execution, Ox redacts its value (and the encodings `SecretAttempt.forms` already covers) from:

- the script's return value and console output,
- invocation records in the open generation, including the earlier `service.invoke` outcome that carried the token,
- service logs.

This extends `SecretAttempt.redact` / `redactLive`, which already cover action results, browser events, and web console output.

Known limit: redaction catches exact and common encodings, not deliberately transformed values.

## Skill changes

### `skills/authentication`: multi-step sign-in pattern

- Sign-in is ordinary actions. Each returns `{ status: "signedIn" }` or `{ status: "needsInput", fields, state }`.
- Collect codes with the secret card (`ox.secret.add` without `value`, type `token`) and pass the reference; never in chat.
- Pipe credential fields from an action result into `ox.secret.add({ value })` in the same script, immediately, before any other work. Never print, return, or store them.
- On an auth failure, call the service's refresh action once and pipe its result the same way. If refresh fails, restart sign-in.
- Non-secret values (device ID, install ID, phone number) are plain action inputs, not secrets.

### `skills/evolve/references/api-service.md`

- Document references in `request` headers, query, and body.
- Services with custom sign-in use `auth: { type: "none" }` and send `{ $secret }` headers, rather than a fixed auth type.
- Sign-in and refresh actions return credential fields in their result; mark them `requireApproval: true`.

## Hinge example

```js
// verifyLogin returns { token, expires, identityId } from POST auth/sms/v2
const r = await ox.service.invoke({ name: "api:hinge:verifyLogin", input: { otp: { $secret: "hinge-otp" }, deviceId, installId, phone } });
if (r.status === "needsInput") return r;                // email code step
await ox.secret.add({ purpose: "Save Hinge session", key: "hinge", type: "token", serviceID: "api:hinge", value: { token: `Bearer ${r.token}` } });
return { status: "signedIn", expires: r.expires };    // token never reaches the model
```

Device and session headers are plain values. Only the bearer token is a secret.

## Risks

- **Model compliance.** A mistaken or injected script could print or encode the token. Redaction catches exact copies only. The token still never leaves the device unless the script sends it out, and API requests stay confined to the owning service's base URL.
- **Not atomic across steps.** If the script fails between a refresh and `secret.add`, the new token is lost and the user signs in again. The skill orders the save first.
- **Records.** Redaction must run before the generation is persisted and before results are shown in the UI; otherwise the token lands in `turns.jsonl`.
- **Background runs.** Refresh works without the user; sign-in needs a code and therefore a foreground conversation.

## Not doing

- Declarative sign-in flows in `service.json`.
- New `request` parameters, new `install` objects, or manifest flags for credentials.
- Handler-initiated user prompts.
- A general form primitive (`ox.user.input`). Possible later; not needed here.

## Verification

- `secret.add` with and without `value`; replacement; approval denial; wrong `serviceID`.
- References in header, query, body; non-owner and unpassed references; literal `Authorization` still rejected.
- The token absent from script output, invocation records, `turns.jsonl`, logs, and UI after a pipe.
- Hinge: SMS sign-in, 412 email step, authenticated read (`likelimit`), refresh replacing the secret, and recovery after a failed refresh.

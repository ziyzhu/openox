# App-wide vault

## Goal

Let people keep named secrets in Ox and let an agent request their use without receiving their values. The vault is app-wide, like Services and model-provider settings. It does not live in a Profile or sync through Profile files.

The vault data model is `String → String`: a key maps to a JSON string. For example, `openai.primary` could hold `{"apiKey":"…"}`, and `example.login` could hold `{"username":"…","password":"…"}`. The vault does not encode provider, service, or browser behavior. Each consumer defines the JSON fields it accepts and the destination to which it may send them.

The model and its JavaScript VM may learn that a key exists and request an authorized use. Only the iOS Host may read a value. There is no `ox.vault.get()`, value argument to a VM write function, generic template substitution, or secret-bearing result.

## Current storage

| State | Current owner and location |
| --- | --- |
| Provider definitions and default model | App-wide UserDefaults: `llm.providerCatalog` and `llm.defaultModel` |
| Provider API keys | Generic-password Keychain items under the bundle-derived Ox service, with accounts `api:<credential ID>` and raw string values |
| Provider OAuth tokens | Keychain accounts such as `oauth:<credential ID>` |
| API-service credentials | Keychain accounts `service:api:<identity hash>` containing versioned JSON envelopes with a configuration binding, secret, and optional username or OAuth data |
| Remote MCP OAuth | Keychain accounts `oauth:mcp:<endpoint hash>` |
| Website sessions | One persistent app-wide `WKWebsiteDataStore`, separate from Keychain and Profiles |

`Credentials.swift` owns the Keychain access. Standard provider credential IDs include the provider ID and a digest of its endpoint and authentication configuration. API-service envelopes include a binding digest of the service's authentication configuration and destination. Both prevent ordinary configuration edits from silently sending a stored secret to a new endpoint. Existing Keychain items use `AfterFirstUnlock` accessibility, which supports background use and may transfer in an encrypted device backup.

## Proposed storage

Use the existing bundle-derived Keychain service. Store each vault entry as one generic-password item with account `vault:<key>` and value equal to the validated JSON string. Enumerate only `vault:` account names for the Vault list; no second catalog of secret values is needed. Keys must be nonempty, bounded strings and unique within the app. Replacing a key replaces its value; renaming a key is not part of the first version.

Persist one versioned app-wide binding map outside the vault values. A binding records the consumer kind, consumer identity, destination/configuration fingerprint, and vault key. It contains no secret value. Provider and API-service resolvers check the fingerprint again immediately before use. A changed URL, authentication configuration, service repository, or service identity makes the old binding unavailable until the person approves a new one. The binding map can live in UserDefaults alongside the provider catalog; the exact storage key and encoding must be recorded in the storage map when implemented.

New vault entries should use `AfterFirstUnlockThisDeviceOnly` so scheduled background Actions can use them after the first device unlock while the entry does not migrate to another device through a backup. This is a change from the current credential retention policy and must be explicit in migration and UI copy. [Apple's Keychain accessibility guidance](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility) describes the lock-state and device-transfer choices.

Provider and API-service API keys, bearer tokens, and Basic credentials move behind vault bindings. Provider OAuth, API-service OAuth refresh state, remote MCP OAuth, and website state retain their current owners in the first version. Compiled-in provider secrets are not vault entries.

## Native UI

Add **Vault** to app Settings alongside Services. The list shows keys, availability, and consumers bound to each key. A detail page hides the JSON value by default and offers native Reveal, Edit, and Delete controls. Reveal and editing never return a value through an Ox Action. Validate that edited text is JSON before saving it. Updating a key used by multiple consumers must show all affected bindings before the replacement is confirmed. Deletion requires unbinding its consumers first.

Preserve the current model-provider and API-service credential screens. Their API-key, token, and username/password fields remain the normal way to enter or replace credentials for that consumer; the Host serializes those fields into the vault JSON value and maintains its binding. OAuth sign-in remains on its current UI path. A provider or service screen must not silently rotate a key shared with another consumer: replacing only that consumer's credential creates or selects a dedicated key, while editing the shared entry is an explicit choice in Vault.

Provider deauthentication and API-service sign-out remove the consumer's binding. They also remove an unshared entry that Ox created solely for that consumer, preserving the current expectation that signing out clears its local credential. A manually named or shared entry remains in Vault until the person deletes it there.

The native Vault page may reveal a value to the person operating the device. That is distinct from returning it to the VM or model. Revealed values should be masked again when the page leaves the foreground and must never be placed in diagnostic logs.

## Ox functions and approvals

| Proposed function | Behavior |
| --- | --- |
| `ox.vault.list()` | Return keys and availability, without values or JSON contents |
| `ox.vault.set({ key, purpose })` | Open native entry or editing UI; receive and validate the JSON value in the Host |
| `ox.vault.delete({ key, purpose })` | Remove an unbound entry after confirmation |
| `ox.provider.assignKey({ id, key, purpose })` | Bind an entry containing `apiKey` to a bearer or API-key provider |
| `ox.service.assignKey({ domain, key, purpose })` | Bind a compatible entry to an API service's existing authentication configuration |

These are proposed names. `ox.provider.authenticate` remains the one-step provider flow: its existing secure field saves `{"apiKey":"…"}` and binds the entry. Existing API-service sign-in similarly writes `{"apiKey":"…"}`, `{"token":"…"}`, or `{"username":"…","password":"…"}` according to its existing auth type. The API-service manifest schema does not change.

An agent may request an assignment but may not approve it. A native confirmation shows the vault key, consumer name, exact destination, and fields that will be supplied. This secret-use confirmation is separate from the ordinary Action policy: an Action set to Allow cannot bypass it, and the first version offers no blanket Always Allow for new assignments. After approval, provider requests and authenticated API-service Actions may use the bound value at that exact destination; normal Action permissions still apply to each API-service Action. Revoking the binding stops future use. This does not change the current defaults for `ox.provider.save` or `ox.provider.deauthenticate`.

No general `ox.vault.use({ key, action, args })` is permitted. `ox.web.fetch`, filesystem Actions, model-generated JavaScript, and arbitrary MCP calls cannot interpolate vault values. Each future consumer needs a Host-owned adapter that validates its destination and expected JSON fields, obtains the applicable approval, and returns only a bounded status or ordinary Action result. Logs and approval arguments may include key names and destination identifiers, never values.

## Browser use

Browser credential use needs a separate design and should follow the Host-bound provider and API-service work. Ox currently permits model-supplied JavaScript through `ox.web.browser.executeScript`. Once a password is filled into a page, that page's scripts can read it, and a later model-controlled script could return it. A separate WebKit content world does not hide DOM changes from page scripts; [Apple documents that DOM changes are visible across content worlds](https://developer.apple.com/documentation/webkit/webpage/calljavascript%28_%3Aarguments%3Ain%3Acontentworld%3A%29). Redacting known strings from results cannot provide a reliable boundary against transformed or encoded output.

For an eventual `ox.web.browser.signInWithVault`, require confirmation for each use, showing the current HTTPS origin and actual credential destination. Recheck the page, frame, form destination, and navigation generation immediately before release. During the handoff, suspend model-controlled page inspection and scripting, stop capture, clear injected scripts, and return no credential-bearing page result. Discard the sign-in page before normal browser control resumes. The receiving website necessarily sees the credential; an arbitrary site may also echo or persist it in page-accessible state, so this flow cannot promise absolute secrecy from later browser inspection without further restrictions. Until that boundary is designed and verified, use the existing user-operated `ox.web.browser.waitForUserInteraction` path for browser login.

## Migration and verification

Implement compatibility only in `StorageMigrator` before provider and service consumers read old state. Copy existing provider API keys and eligible API-service credentials into deterministic, collision-safe vault keys; validate their new JSON and write bindings to the same destinations. Preserve recoverable source items until the new records and bindings have been verified. Handle interrupted migration and already-migrated entries idempotently. Leave OAuth and website state untouched. Document the new Keychain accounts, binding map, backup policy, and deletion behavior in `.agents/skills/storage-migrations/references/storage.md` in the implementation change.

Verify an upgrade using credentials written by the predecessor build, then check repeat launch, collision, interruption, and unknown-future-format behavior. Exercise provider and API-service edit screens, shared-key replacement, destination changes, deauthentication, deletion, background availability, and a real authenticated request. Confirm that VM results, Action history, logs, and chat transcripts contain no vault values. Run the required storage-migration gate, typecheck, localization check after catalog changes, and a `sim` build and manual flow on an existing numbered QA simulator.

## Delivery order

1. Add the Keychain-backed vault and native Vault page, including secure entry, reveal, edit, and delete.
2. Add destination bindings and migrate provider API keys while preserving all current provider entry points.
3. Migrate API-service API-key, bearer, and Basic credentials while preserving their current sign-in UI.
4. Add the VM functions and mandatory binding confirmation.
5. Design and verify protected browser use separately before exposing a browser vault Action.

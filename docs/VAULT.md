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
| Repository publication PAT | Keychain account `pat:service-repository:github`; a user-entered GitHub token used only for OpenOx service proposals |
| Website sessions | One persistent app-wide `WKWebsiteDataStore`, separate from Keychain and Profiles |

`Credentials.swift` owns the app Keychain access. It also stores bundled-provider subscription bundles at `oauth:chatgpt`, `oauth:xai`, `oauth:github-copilot`, and `oauth:openrouter`, plus catalog-provider OAuth bundles at `oauth:<credential ID>`. Remote MCP envelopes include the discovered OAuth server, client registration (possibly a client secret), and tokens. API-service OAuth tokens share the `service:api:` envelope family with API keys, bearer tokens, and Basic credentials. The old `oauth:service-repository:github` account is removed by `StorageMigrator`; it must never become a vault entry. Simulator bootstrap credentials in the developer host Keychain are outside the app vault.

Standard provider credential IDs include the provider ID and a digest of its endpoint and authentication configuration. Registered custom adapters may retain a provider-ID credential instead and enforce their own destination. API-service envelopes include a binding digest of the service's authentication configuration and destination. Existing Keychain items use `AfterFirstUnlock` accessibility, which supports background use and may transfer in an encrypted device backup. The current `Credentials` cache does not distinguish a missing item from a failed Keychain read, and some writers ignore Keychain failures. Vault operations need checked reads, writes, and deletes with explicit locked, missing, corrupt, and unavailable states.

## Credential classes and ownership

| Class | Examples | Vault treatment |
| --- | --- | --- |
| User-entered reusable secret | Provider API key or bearer token, API-service API key/bearer/Basic fields, repository publication PAT | Named vault entry with explicit consumer bindings; native reveal, edit, and delete |
| Flow-managed authorization | Provider and subscription OAuth bundles, API-service OAuth tokens, remote MCP OAuth registration and tokens | Keep a Host-managed Keychain item and its existing refresh and sign-out owner; show connection status and Reconnect/Disconnect in Vault without exposing or accepting arbitrary token JSON |
| Website state | Cookies and other WebKit data | Keep in `WKWebsiteDataStore`; show site/session management separately from Keychain entries |
| App-supplied credential | Compiled-in provider secrets | No vault entry or user-facing reveal |

The Vault screen is an app-wide inventory of user-controlled credentials and connections. Only the first class uses generic JSON entries or can be assigned to another consumer. A flow-managed token, OAuth client registration, or website cookie is never an assignable vault key. Native sign-in screens continue to own OAuth consent, token refresh, and revocation. The repository PAT is a publication credential for OpenOx's GitHub target; it must not be shared with an LLM provider or arbitrary service simply because it is stored in the same vault.

## Proposed storage

Use the existing bundle-derived Keychain service. Store each reusable entry as one generic-password item with account `vault:<key>` and value equal to the validated JSON object string. Enumerate only `vault:` account names for the reusable-entry list; no second catalog of secret values is needed. Keys must be nonempty, bounded, unique within the app, and treated as potentially sensitive metadata in logs and agent results. Reject reserved names and ambiguous Unicode normalization. Bound the JSON byte size and nesting, and reject duplicate object fields before storing it. Replacing a key replaces its value; renaming a key is not part of the first version.

Persist one versioned app-wide binding map outside the vault values. A binding records the consumer kind, consumer identity, exact destination/configuration fingerprint, expected JSON fields, and vault key. It contains no secret value. Provider, API-service, and repository-publication resolvers check the fingerprint and field schema immediately before use, then construct the request within the Host. A changed URL, authentication configuration, repository, service identity, or publication target makes the old binding unavailable until the person approves a new one. Bindings and Keychain entries cannot be written atomically across stores: publish a binding only after its item is durably saved; on launch, reconcile missing items and malformed or unknown-future map versions by making bindings unavailable without deleting recoverable secrets. The binding map can live in UserDefaults alongside the provider catalog; the exact storage key and encoding must be recorded in the storage map when implemented.

New vault entries should use `AfterFirstUnlockThisDeviceOnly` so scheduled background Actions can use them after the first device unlock while the entry does not migrate to another device through a backup. This is a change from the current credential retention policy and must be explicit in migration and UI copy. A restored binding map can therefore refer to absent entries: show Reconnect/Enter again, never silently create a usable binding. The plan must also specify whether existing flow-managed OAuth items retain their current migratable policy or move to the device-only policy; changing them requires a separate migration and reauthentication behavior. [Apple's Keychain accessibility guidance](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility) describes the lock-state and device-transfer choices.

Provider and API-service API keys, bearer tokens, and Basic credentials move behind vault bindings. The user-entered repository publication PAT follows the same pattern when that flow is migrated, with a binding restricted to the registered OpenOx publication target and its GitHub destination. Provider OAuth, API-service OAuth refresh state, remote MCP OAuth, and website state retain their current owners in the first version. Compiled-in provider secrets are not vault entries. For API services, decode the existing envelope and migrate only non-OAuth auth kinds; do not interpret an OAuth access token as a reusable bearer entry.

## Native UI

Add **Vault** to app Settings alongside Services. The reusable-entry list shows keys, availability, and consumers bound to each key. A separate Connections section shows managed OAuth and website sessions using their owning flows' status and sign-out controls; it does not decode those items as user-editable JSON. A reusable entry's detail page hides the JSON value by default and offers native Reveal, Edit, and Delete controls. Reveal and editing never return a value through an Ox Action. Validate the expected object fields for every bound consumer before saving an edit. Updating a key used by multiple consumers must show all affected bindings before the replacement is confirmed. Deletion requires unbinding its consumers first. A missing device-only item after restore appears as unavailable and may be entered again.

Preserve the current model-provider and API-service credential screens. Their API-key, token, and username/password fields remain the normal way to enter or replace credentials for that consumer; the Host serializes those fields into the vault JSON value and maintains its binding. OAuth sign-in and repository publication authorization remain on their current native UI paths. A provider or service screen must not silently rotate a key shared with another consumer: replacing only that consumer's credential creates or selects a dedicated key, while editing the shared entry is an explicit choice in Vault.

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

No general `ox.vault.use({ key, action, args })` is permitted. `ox.web.fetch`, filesystem Actions, model-generated JavaScript, and arbitrary MCP calls cannot interpolate vault values. Each future consumer needs a Host-owned adapter that validates its destination and expected JSON fields, obtains the applicable approval, and returns only a bounded status or ordinary Action result. Agent-visible keys and approval arguments may include names and destination identifiers, never values. Logs should record bounded identifiers or counts and failure states, and must not assume that a user-chosen key name is safe to log verbatim.

## Browser use

Browser credential use needs a separate design and should follow the Host-bound provider and API-service work. Ox currently permits model-supplied JavaScript through `ox.web.browser.executeScript`. Once a password is filled into a page, that page's scripts can read it, and a later model-controlled script could return it. A separate WebKit content world does not hide DOM changes from page scripts; [Apple documents that DOM changes are visible across content worlds](https://developer.apple.com/documentation/webkit/webpage/calljavascript%28_%3Aarguments%3Ain%3Acontentworld%3A%29). Redacting known strings from results cannot provide a reliable boundary against transformed or encoded output.

For an eventual `ox.web.browser.signInWithVault`, require confirmation for each use, showing the current HTTPS origin and actual credential destination. Recheck the page, frame, form destination, and navigation generation immediately before release. During the handoff, suspend model-controlled page inspection and scripting, stop capture, clear injected scripts, and return no credential-bearing page result. Discard the sign-in page before normal browser control resumes. The receiving website necessarily sees the credential; an arbitrary site may also echo or persist it in page-accessible state, so this flow cannot promise absolute secrecy from later browser inspection without further restrictions. Until that boundary is designed and verified, use the existing user-operated `ox.web.browser.waitForUserInteraction` path for browser login.

## Migration and verification

Implement compatibility only in `StorageMigrator` before provider and service consumers read old state. Copy existing provider API keys and eligible non-OAuth API-service credentials into deterministic, collision-safe vault keys; validate their new JSON and write bindings to the same destinations. Migrate the repository PAT only with its publication adapter, preserving the fixed OpenOx target; never migrate legacy third-party repository OAuth into it. Preserve recoverable source items until the new records and bindings have been verified. Handle interrupted migration and already-migrated entries idempotently. Leave OAuth and website state untouched. Document the new Keychain accounts, binding map, backup policy, and deletion behavior in `.agents/skills/storage-migrations/references/storage.md` in the implementation change.

Verify an upgrade using credentials written by the predecessor build, then check repeat launch, collision, interruption, restored bindings without Keychain items, and unknown-future-format behavior. Exercise provider and API-service edit screens, shared-key replacement, destination changes, deauthentication, deletion, background availability, and a real authenticated request. Include a repository proposal PAT when its adapter migrates. Verify that managed OAuth refresh and disconnect still work, without making their token envelopes assignable. Confirm that VM results, Action history, logs, and chat transcripts contain no vault values. Run the required storage-migration gate, typecheck, localization check after catalog changes, and a `sim` build and manual flow on an existing numbered QA simulator.

## Delivery order

1. Add the Keychain-backed vault and native Vault page, including secure entry, reveal, edit, and delete.
2. Add destination bindings and migrate provider API keys while preserving all current provider entry points.
3. Migrate API-service API-key, bearer, and Basic credentials while preserving their current sign-in UI.
4. Migrate the repository publication PAT behind a target-specific binding; list managed OAuth and website connections through their existing owners.
5. Add the VM functions and mandatory binding confirmation.
6. Design and verify protected browser use separately before exposing a browser vault Action.

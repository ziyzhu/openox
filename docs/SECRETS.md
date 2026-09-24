# App-wide secrets

## Goal

Let people keep agent-manageable named secrets in Ox and let an agent request their use without receiving their values. Secrets are app-wide, like Services and model-provider settings. They do not live in a Profile or sync through Profile files. Flow-managed OAuth tokens and website sessions remain outside Secrets.

The data model is `String → String`: a stable key maps to a JSON object string. For example, `openai.primary` could hold `{"apiKey":"…"}`, and `example.login` could hold `{"username":"…","password":"…"}`. Each entry also has an editable display name in nonsecret metadata. The value does not encode provider, service, or browser behavior. Each consumer defines the JSON fields it accepts and the destination to which it may send them.

The model and its JavaScript VM may learn that a key exists and request an authorized use. Only the iOS Host may read a value. There is no `ox.secret.get()`, value argument to a VM write function, generic template substitution, or secret-bearing result.

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

`Credentials.swift` owns the app Keychain access. It also stores bundled-provider subscription bundles at `oauth:chatgpt`, `oauth:xai`, `oauth:github-copilot`, and `oauth:openrouter`, plus catalog-provider OAuth bundles at `oauth:<credential ID>`. Remote MCP envelopes include the discovered OAuth server, client registration (possibly a client secret), and tokens. API-service OAuth tokens share the `service:api:` envelope family with API keys, bearer tokens, and Basic credentials. The old `oauth:service-repository:github` account is removed by `StorageMigrator`; it must never become a secret entry. Simulator bootstrap credentials in the developer host Keychain are outside the app secret.

Standard provider credential IDs include the provider ID and a digest of its endpoint and authentication configuration. Registered custom adapters may retain a provider-ID credential instead and enforce their own destination. API-service envelopes include a binding digest of the service's authentication configuration and destination. Existing Keychain items use `AfterFirstUnlock` accessibility, which supports background use and may transfer in an encrypted device backup. The current `Credentials` cache does not distinguish a missing item from a failed Keychain read, and some writers ignore Keychain failures. Secret operations need checked reads, writes, and deletes with explicit locked, missing, corrupt, and unavailable states.

## Credential classes and ownership

| Class | Examples | Secret treatment |
| --- | --- | --- |
| User-entered reusable secret | Provider API key or bearer token, API-service API key/bearer/Basic fields, repository publication PAT | Named secret entry with explicit consumer bindings; native reveal, edit, and delete |
| Flow-managed authorization | Provider and subscription OAuth bundles, API-service OAuth tokens, remote MCP OAuth registration and tokens | Keep separate Host-managed Keychain items with their existing refresh and sign-out owners; show status and Reconnect/Disconnect in each owner's UI, never as assignable secret keys |
| Website state | Cookies and other WebKit data | Keep in `WKWebsiteDataStore` and manage through website controls outside Secrets |
| App-supplied credential | Compiled-in provider secrets | No secret entry or user-facing reveal |

The Secrets screen lists only agent-manageable reusable entries. A flow-managed token, OAuth client registration, or website cookie is not a secret entry. Native sign-in screens continue to own OAuth consent, token refresh, revocation, and connection status. The repository PAT is a publication credential for OpenOx's GitHub target; it must not be shared with an LLM provider or arbitrary service simply because it is stored with other secrets.

## Proposed storage

Use the existing bundle-derived Keychain service. Store each reusable entry as one generic-password item with account `secret:<key>` and value equal to the validated JSON object string. Keep one versioned app-wide metadata map outside Keychain values. Its version 1 logical shape is:

```text
SecretIndex {
  version: 1
  entries: [SecretEntry]
  bindings: [SecretBinding]
}

SecretEntry {
  key: String
  displayName: String
  origin: named | generatedFor(consumerKind, consumerID)
  usePolicy: reusable | publicationOnly
}

SecretBinding {
  consumerKind: provider | apiService | repositoryPublication
  consumerID: String
  secretKey: String
  destination: String
  configurationFingerprint: String
  requiredFields: [String]
}
```

`key` is the immutable entry identifier and the suffix of its Keychain account. `displayName` is editable without changing bindings; the native editor shows the key. `origin` distinguishes a named entry from a reusable entry generated for one consumer when that consumer signs out; it never represents an OAuth item. `usePolicy` prevents the OpenOx repository publication PAT from being assigned to an unrelated consumer. Neither the metadata map nor a binding contains a value, a value fragment, or a credential-derived digest. The map retains metadata for missing device-only Keychain items after a restore. Enumerate `secret:` Keychain accounts as well to detect saved entries missing from the map, but do not infer their origin or use policy and do not make them assignable automatically.

Accept user keys of 1–128 ASCII characters matching `[A-Za-z0-9][A-Za-z0-9._-]*`; compare them exactly and reserve the `ox.` prefix for generated entries. Require a nonempty display name of at most 80 Unicode scalar values, normalized to NFC. Treat keys and display names as potentially sensitive metadata in logs and agent results. Require a nonempty, flat JSON object of string fields, at most 16 KiB encoded as UTF-8, with no duplicate field names. Replacing a key replaces its value; renaming a key is not part of the first version. Consumer adapters also validate the fields they use. The exact bounds and encoding become storage compatibility rules once implemented.

Entry keys are unique in the index; each consumer has at most one active binding, and every binding references an indexed entry. `consumerID` is the stable provider credential ID, API-service identity, or fixed OpenOx publication identity, rather than an agent-supplied label. The Host adapter derives the current destination and configuration fingerprint from the consumer's trusted configuration, shows the full destination and required fields for native approval, and writes the binding only after approval. `destination` is the adapter's canonical permitted request destination or scope; the adapter must prevent credentials from following redirects outside it. The fingerprint covers the versioned destination, authentication configuration, and service or publication identity. At use time, the adapter checks the current consumer identity, fingerprint, destination, entry policy, and JSON field schema immediately before reading the Keychain value and constructing the request. A changed URL, authentication configuration, service repository, service identity, or publication target makes the old binding unavailable until the person approves a new one.

The metadata map and Keychain items cannot be written atomically. Save and verify a value before publishing its metadata or binding. On launch, reconcile missing items and orphaned `secret:` items without deleting recoverable secrets. A missing item leaves its entry and bindings visible but unavailable. An orphaned item is unavailable and unassignable until native recovery establishes its metadata and policy. Malformed or unknown-future map versions make all bindings unavailable until they can be read safely. Record the final UserDefaults key and encoding in the storage map when implemented.

New secret entries should use `AfterFirstUnlockThisDeviceOnly` so scheduled background Actions can use them after the first device unlock while the entry does not migrate to another device through a backup. This is a change from the current credential retention policy and must be explicit in migration and UI copy. A restored binding map can therefore refer to absent entries: show Reconnect/Enter again, never silently create a usable binding. Flow-managed OAuth items retain their current `AfterFirstUnlock` policy when their account names move; changing that policy would require a separate migration and reauthentication behavior. [Apple's Keychain accessibility guidance](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility) describes the lock-state and device-transfer choices.

Provider and API-service API keys, bearer tokens, and Basic credentials move behind secret bindings. The user-entered repository publication PAT follows the same pattern when that flow is migrated, with a binding restricted to the registered OpenOx publication target and its GitHub destination. Flow-managed OAuth stays outside Secrets under three owner-specific Keychain account families:

```text
oauth:model-provider:<credential ID>
oauth:mcp-service:<endpoint hash>
oauth:api-service:<identity hash>
```

The four bundled-provider subscription accounts use their provider IDs as the credential ID. Catalog-provider OAuth retains its existing destination-scoped credential ID. Remote MCP OAuth retains its endpoint hash. API-service OAuth retains its identity hash, owner, and envelope format while leaving the mixed `service:api:<identity hash>` account family. OAuth refresh and sign-out remain with each consumer; website state retains its WebKit owner. Compiled-in provider secrets are not secret entries. For API services, decode the existing envelope and migrate non-OAuth auth kinds to secret entries; do not interpret an OAuth access token as a reusable bearer entry.

## Native UI

Add **Secrets** to app Settings alongside Services. The list shows display names and marks missing values unavailable; tapping a row opens its detail page. The page title is Secrets, with no repeated section heading. A plus icon in the toolbar opens the **Add Secret** editor. The detail page shows each named field and its single-line value, followed by Edit and Delete controls. It does not expose the internal secret key, consumer list, or Disconnect action. The editor and inline chat card present named secure fields with Add field and Remove field controls; the Host serializes them into a flat JSON object. Validation errors appear as plain text under the fields. Deleting an entry removes its internal bindings, so any connection using it needs setup again. Editing never returns a value through an Ox Action. A missing device-only item after restore appears as unavailable and may be entered again.

Preserve the current model-provider and API-service credential screens. Their API-key, token, and username/password fields remain the normal way to enter or replace credentials for that consumer; the Host serializes those fields into the secret JSON value and maintains its binding. OAuth sign-in and repository publication authorization remain on their current native UI paths. A provider or service screen must not silently rotate a key shared with another consumer: replacing only that consumer's credential creates or selects a dedicated key, while editing the shared entry is an explicit choice in Secrets.

For agent-requested entry, `ox.secret.add` asks the Host to render a native secure card inline in the chat. The card shows the proposed key and lets the person set its display name and string fields. The serialized value goes directly to the Host; neither the card's fields nor its input events enter the VM, Action arguments, Action history, or chat transcript. The agent receives only the key and saved or cancelled status. The agent may request the card but cannot define its secure fields or submission handler. The existing provider authentication sheet remains available from Settings. After saving the entry, the agent may call `ox.provider.connect` with its key; native confirmation then shows the provider, required fields, and exact destination before creating a binding.

Provider deauthentication and API-service sign-out remove the consumer's binding. They also remove an unshared entry that Ox created solely for that consumer, preserving the current expectation that signing out clears its local credential. A manually named or shared entry remains in Secrets until the person deletes it there.

The native detail page displays the value upon opening. That is distinct from returning it to the VM or model. Clear the displayed value when the page leaves the foreground and never place it in diagnostic logs.

## Ox functions and approvals

| Proposed function | Behavior |
| --- | --- |
| `ox.secret.list({ purpose })` | Return keys and availability, without values or JSON contents |
| `ox.secret.add({ key, purpose })` | Open a native secure entry or editing card inline in chat; receive and validate the JSON value in the Host |
| `ox.secret.delete({ key, purpose })` | Remove an entry and its internal bindings after confirmation |
| `ox.provider.connect({ id, credential, purpose })` | Connect a provider using `{ kind: "secret", secretKey }` or `{ kind: "oauth" }`; return status without a value |

`credential.kind` selects an existing secret entry or the managed OAuth flow, not the HTTP authentication method. The Host reads the provider definition to determine which choice is valid, which fields are needed, and how to authenticate requests. `secret` accepts an existing entry identifier and opens native destination confirmation; `oauth` starts the existing managed sign-in flow and creates no assignable secret entry. `ox.secret.add` owns new secret entry and does not need a separate `enter` mode: every call opens native secure input and never accepts a value argument. The current provider definition has one authentication configuration and one active binding at most. Multiple authentication slots would require an explicit provider-definition change and a declared slot identifier; the agent cannot invent an authentication type or destination. Keep `ox.provider.authenticate` working for existing callers through its current native entry or OAuth flow. Existing API-service sign-in similarly writes `{"apiKey":"…"}`, `{"token":"…"}`, or `{"username":"…","password":"…"}` according to its existing auth type. API-service secret bindings are managed through that native sign-in flow for now; there is no agent-facing service assignment function. The API-service manifest schema does not change.

An agent may request an assignment but may not approve it. A native confirmation shows the secret key, consumer name, exact destination, and fields that will be supplied. This secret-use confirmation is separate from the ordinary Action policy: an Action set to Allow cannot bypass it, and the first version offers no blanket Always Allow for new assignments. After approval, provider requests and authenticated API-service Actions may use the bound value at that exact destination; normal Action permissions still apply to each API-service Action. Revoking the binding stops future use. This does not change the current defaults for `ox.provider.save` or `ox.provider.deauthenticate`.

No general `ox.secret.use({ key, action, args })` is permitted. `ox.web.fetch`, filesystem Actions, model-generated JavaScript, and arbitrary MCP calls cannot interpolate secret values. Each future consumer needs a Host-owned adapter that validates its destination and expected JSON fields, obtains the applicable approval, and returns only a bounded status or ordinary Action result. Agent-visible keys and approval arguments may include names and destination identifiers, never values. Logs should record bounded identifiers or counts and failure states, and must not assume that a user-chosen key name is safe to log verbatim.

## Browser use

Browser credential use needs a separate design and should follow the Host-bound provider and API-service work. Ox currently permits model-supplied JavaScript through `ox.web.browser.executeScript`. Once a password is filled into a page, that page's scripts can read it, and a later model-controlled script could return it. A separate WebKit content world does not hide DOM changes from page scripts; [Apple documents that DOM changes are visible across content worlds](https://developer.apple.com/documentation/webkit/webpage/calljavascript%28_%3Aarguments%3Ain%3Acontentworld%3A%29). Redacting known strings from results cannot provide a reliable boundary against transformed or encoded output.

For an eventual `ox.web.browser.signInWithSecret`, require confirmation for each use, showing the current HTTPS origin and actual credential destination. Recheck the page, frame, form destination, and navigation generation immediately before release. During the handoff, suspend model-controlled page inspection and scripting, stop capture, clear injected scripts, and return no credential-bearing page result. Discard the sign-in page before normal browser control resumes. The receiving website necessarily sees the credential; an arbitrary site may also echo or persist it in page-accessible state, so this flow cannot promise absolute secrecy from later browser inspection without further restrictions. Until that boundary is designed and verified, use the existing user-operated `ox.web.browser.waitForUserInteraction` path for browser login.

## Migration and verification

Implement compatibility only in `StorageMigrator` before provider and service consumers read old state. Copy existing provider API keys and eligible non-OAuth API-service credentials into deterministic, collision-safe secret keys; validate their new JSON and write bindings to the same destinations. Move bundled and catalog-provider OAuth, remote MCP OAuth, and API-service OAuth items to their owner-specific `oauth:` accounts without changing their envelope formats, refresh behavior, or sign-out owners; do not expose them through secret functions. Migrate the repository PAT only with its publication adapter, preserving the fixed OpenOx target; never migrate legacy third-party repository OAuth into it. Preserve recoverable source items until the new records and bindings have been verified. Handle interrupted migration and already-migrated entries idempotently, and reject collisions rather than overwriting a different credential. Leave website state untouched. Document the new Keychain accounts, binding map, backup policy, and deletion behavior in `.agents/skills/storage-migrations/references/storage.md` in the implementation change.

Verify an upgrade using credentials written by the predecessor build, then check repeat launch, collision, interruption, restored bindings without Keychain items, and unknown-future-format behavior. Exercise provider and API-service edit screens, shared-key replacement, destination changes, deauthentication, deletion, background availability, and a real authenticated request. Include a repository proposal PAT when its adapter migrates. Verify that managed OAuth refresh and disconnect still work, without making their token envelopes assignable. Confirm that VM results, Action history, logs, and chat transcripts contain no secret values. Run the required storage-migration gate, typecheck, localization check after catalog changes, and a `sim` build and manual flow on an existing numbered QA simulator.

## Delivery order

1. Add the Keychain-backed secret and native Secrets page, including secure entry, reveal, edit, and delete.
2. Add destination bindings and migrate provider API keys to Secrets and provider OAuth to `oauth:model-provider:` while preserving all current provider entry points.
3. Migrate API-service API-key, bearer, and Basic credentials to Secrets and API-service OAuth to `oauth:api-service:` while preserving their current sign-in UI.
4. Migrate remote MCP OAuth to `oauth:mcp-service:` and the repository publication PAT behind a target-specific Secret binding; keep OAuth and website connections in their existing UI flows.
5. Add the VM functions, Host-owned inline Secret entry card, and mandatory binding confirmation.
6. Design and verify protected browser use separately before exposing a browser secret Action.

# Editable model providers

Let an Ox agent inspect and edit provider definitions and request authentication through the same UI used in Settings. Provider configuration becomes serialized data consumed by existing native API implementations.

## Agreed contract

- A provider represents one endpoint, one API format, and one credential scope.
- Separate regional account configurations have separate opaque provider IDs. Region does not belong in model selection and is not inferred by parsing IDs.
- Providers with multiple API formats become separate entries.
- A provider contains its model list. Every listed model must support tools; there is no `tools` field.
- Provider documents have no version field. Persisted-format compatibility is handled at the owning storage level.
- Credentials, authentication status, token expiry, and resolved clients are separate from provider definitions.
- Standard OAuth is configuration-driven. Explicit registered adapters handle exceptional exchanges or account requirements.
- Settings and agent-requested authentication use shared UI and completion logic.
- There are no public provider test or model-discovery functions. Models are supplied in definitions.

## Data model

`Provider` contains `id`, `name`, `url`, `auth`, `api`, optional API-specific `options`, and `models`.

`api` selects a tagged configuration for OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, or Gemini GenerateContent. Each configuration permits only options understood by its native implementation. Start with options required by existing integrations, including token-field selection, reasoning encoding and replay, cache behavior, streaming transport, session headers, and non-secret request extensions. Represent model-dependent settings as explicit typed model options where necessary, rather than retaining executable closures in definitions.

`auth` is a tagged union of `none`, `bearer`, `api-key`, `oauth`, and `custom`. Bearer and API-key credentials are stored under the provider identity; API-key configuration includes its header name. Optional authentication remains supported for local servers. OAuth configuration contains the public client ID, scopes, token URL, request encoding, and either authorization-code or device-code settings. Authorization-code handling always uses PKCE and state. Custom authentication identifies a registered implementation, not executable code in a document.

`Model` contains `id`, `name`, optional `wireID`, context and output token limits, input and output modalities, and supported reasoning efforts. `wireID` defaults to `id`. Omitted capability metadata remains unknown. Selected reasoning effort stays in `ModelSelection`, which contains `providerID`, `modelID`, and optional `reasoningEffort`.

Keep human-facing setup links, notices, and presentation grouping as metadata rather than mixing them with authentication state. Preserve current Settings information when converting built-ins. Visual grouping can continue to offer Global and China choices without making region a second runtime selection coordinate.

## Implementation sequence

### 1. Define the serialization contract and validation

Add native Codable definitions and matching TypeScript-facing shapes for provider documents. Establish one authoritative validation path used by loading, explicit validation, and saving.

Inventory every existing built-in integration against the proposed model before replacing runtime construction. Use that inventory to add only necessary typed options. Cover local optional credentials, regional accounts, ChatGPT fast variants, OpenRouter request policy, and the split protocols currently grouped under Bedrock.

Validate IDs, URLs without embedded credentials, model-ID uniqueness, positive declared token limits, supported API/authentication variants, registered adapter references, and API-specific options. Validation checks configuration without making network requests; it cannot prove tool support or credential validity. Model admission still requires tool-capable metadata or implementation verification.

Deliverable: sanitized representative definitions and focused validation/serialization tests that demonstrate the format fits existing integrations.

### 2. Resolve definitions into existing API implementations

Add a small factory that constructs ProviderClient instances from validated definitions and credential resolvers. Reuse the current transports and provider-neutral message representation.

Convert representative integrations first, then the remaining built-ins. Continue using models.dev-derived bundled model metadata and preserve reviewed overrides in the generation pipeline. Avoid a second independently maintained model catalog.

Resolve a run against a stable definition snapshot. Saving or deleting a provider must not mutate an already-running request. Credential bindings belong to the validated destination; a changed destination must not inherit credentials automatically.

Deliverable: the picker and agent runtime use the same registry of resolved definitions, with existing request behavior preserved.

### 3. Share authentication execution and presentation

Generalize authorization-code exchange, device polling, refresh, expiry, and credential storage where current implementations fit the shared OAuth configuration. Retain small registered implementations for custom exchanges or account-derived request requirements.

Refactor ProviderAuthenticationView so authentication completion and credential persistence no longer depend on the model picker's Save operation. Reuse its secure fields, OAuth/device presentation, account state, errors, and cancellation behavior from both Settings and a focused provider authentication sheet.

OAuth can report successful authorization. Saving a pasted credential reports storage completion, not verified API access. No credentials enter function arguments, results, chat transcripts, or diagnostic logs.

Deliverable: Settings can authenticate every supported definition through the shared implementation, independently of choosing a model.

### 4. Persist user edits and migrate existing state

Keep the existing app-wide ownership of provider configuration initially. Bundled definitions remain the base catalog in code. Persist only additions and complete replacements keyed by provider ID. Effective definitions merge bundled defaults with the saved definitions, without field-level inheritance. Removing a saved override restores its bundled default; removing an added definition removes the provider entirely. Unmodified bundled defaults cannot be deleted. A saved replacement with no models disables a provider for model selection. Expose bundled definitions separately through the read-only `ox.provider.default` function so an agent can inspect or customize one without changing storage.

Persist validated changes atomically and preserve recoverable prior state. Define replacement, deletion, and default-selection behavior explicitly. Removing a saved definition clears its credentials and resets a matching new-chat default. Added providers become unavailable; bundled overrides revert to bundled definitions. References in old chats remain identifiable, and unavailable providers or models require a new selection before another run.

Implement all compatibility handling in StorageMigrator. Map legacy provider ID plus region to the new provider identity for application defaults and every affected chat. Preserve custom-provider identities, credentials, and subscription bundles. Migrate existing endpoint/name records without making startup depend on network discovery. Preserve historical model references with unknown metadata where the predecessor did not persist capabilities.

Append the applicable storage milestones without changing existing identifiers. Update the storage reference and add predecessor-generated sanitized fixtures for upgraded defaults, chats, custom providers, and credential-identity mapping. Verify idempotence, interruption recovery, conflicts, and unknown future storage formats.

Deliverable: upgraded installations retain their configured providers and selections; fresh and repeated launches work without rediscovering the authored model list.

### 5. Expose provider capabilities to Ox agents

Add these functions through the existing OxFunction and host/client infrastructure:

| Function | Behavior |
| --- | --- |
| `ox.provider.default` | Return a fresh copy of bundled definitions without changing the active catalog |
| `ox.provider.list` | Return compact summaries and authentication status |
| `ox.provider.get` | Return a complete definition by ID |
| `ox.provider.validate` | Validate a supplied document without saving or connecting |
| `ox.provider.save` | Validate and create or replace a complete definition |
| `ox.provider.delete` | Remove a saved addition or override and its credentials; overrides revert to bundled defaults |
| `ox.provider.authenticate` | Present shared authentication UI and await completion |
| `ox.provider.deauthenticate` | Clear locally stored authentication and reset account state |

Follow the existing `purpose` convention and permission machinery for user-visible operations. Authentication must use the existing client handoff and suspended-timeout mechanism so user interaction does not exhaust JavaScript execution time. Distinguish authentication completion, no authentication required, cancellation, and failure. Local deauthentication does not claim server-side revocation.

Expose field-specific validation failures. Saving always validates, regardless of whether the caller used validate first. Keep credentials and runtime state out of get results. Update function help and the relevant agent guidance.

Deliverable: an agent can read, edit, save, and authenticate a provider through an Ox chat.

### 6. Verify the integrated flow

Run focused serialization, validation, credential-resolution, and OAuth-state tests with sanitized fixtures. Run `bun run typecheck` and relevant catalog-generation checks. Run `bun run check:localizations` immediately after any localization catalog edit.

Start one repository server and verify its health endpoint. Build, install, and launch with sim on an existing numbered QA simulator and matching ports. Exercise Settings and agent-triggered authentication, pasted credentials, browser OAuth, device authorization, cancellation, deauthentication, editing, deletion, restart persistence, and a subsequent real model request. Keep evidence outside the repository.

After StorageMigrator changes, run the required live `bun run test:storage-migration` gate against the rebuilt DEBUG app and confirm startup logs reach StorageMigrator completion and IOSHost preparation.

Review added lines and complexity before each commit. Resolve the unreleased iOS marketing version through App Store Connect before committing, and run required checks before pushing.

## Separate follow-up

Design model delegation and agent-requested model switching after this provider foundation works. Isolated calls, transferring chat context, and switching the model controlling a chat require their own execution semantics. They do not add provider-management functions in this change.

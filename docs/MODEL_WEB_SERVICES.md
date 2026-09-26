# Model web services implementation plan

Status: implemented and verified on ox-qa-5. All four providers now resolve from their selected web services through the generic adapter. Their site-specific Swift implementations and separate authentication cache are removed. The app builds and launches on ox-qa-5 with iOS 26.5.

## Implementation and verification

- The four canonical Action schemas are shared by SDK/Swift validation and generated authoring documentation. No manifest field or new service kind was added.
- Owned service pages enforce generation isolation, bounded polling/history, append-only snapshots, explicit completion/failure, and truthful cancellation outcomes. Page loss does not resubmit.
- Existing provider IDs, saved selections, website storage, and service source resolution remain unchanged. No persisted format or storage migration is required. Discovered capabilities are refreshed from the service; saved website model IDs resolve without relying on an in-memory discovery cache.
- Qwen, Kimi, Grok, and Claude were copied to Local, implemented, validated, activated, live-tested, and saved through the existing workflow. Per the user's explicit instruction, Codex authored these migrations directly while following the built-in manage-services contracts.
- All four returned live text through the generic adapter. Qwen executed Ox Actions and correctly read a synthetic image and PDF in a real chat; Claude, Kimi, and Grok also read both files through their standard model Actions. Cold-page testing found and fixed Qwen model-state hydration timing. Grok completion verifies the same server conversation even when the captured stream remains open; transient creation-time 404s stay pending without resubmission. Grok cancellation reports requested when remote cancellation is unconfirmed. Ordinary service authentication and model-list Actions remain functional.
- All 69 focused tests pass, covering standard-schema parity, invalid contracts, ordered event cursors, terminal retention, bounded history, unsupported input, preserved native upload checks, verified completion, and cancellation. Typechecking, system-skill checks, bundle compilation, final iOS build/launch, and a post-rebuild generation pass. Saved Local JavaScript exactly matches the bundled source, and the Local repository is clean.


## Outcome

A web service can implement standardized model Actions alongside its ordinary Actions. Ox detects model support from those Actions and adapts them through one generic model provider. Website-specific authentication, submission, attachments, and response parsing live in the service and can be repaired through Ox's existing manage-services workflow.

Model-capable services use the same Local editing, validation, Save, and activation workflow as existing services. An agent can edit them through manage-services without a dedicated repair or recovery subsystem.

The migrated website providers ship as read-only built-in services. To customize one, copy it to Local, resolve the duplicate service through the existing repository conflict-resolution flow, and edit the Local copy. Model capability does not grant special edit access or automatic Local precedence. The model provider uses the same resolved service source as ordinary Actions.

## Existing implementation

- Before this change, `Host/ModelProviders/ProviderClientFactory.swift` selected four site-specific Swift providers: Kimi, Qwen, Grok, and Claude.
- Their internal generation sessions already have start, read, and cancel operations, but their JavaScript is separate from corresponding service Actions.
- `ServiceManager` supplies shared persistent website storage to provider, service, and sign-in pages. Preserve that store and its namespace.
- `ServiceActionScheduler` owns service execution pages. A generation needs page ownership across multiple Action invocations.
- Service Action IDs permit identifier-style names, not dots. Use camelCase standard Action IDs.
- Saved model selections and provider catalog entries refer to existing provider IDs. Preserve their resolution throughout migration.
- ChatGPT's current subscription provider uses a separate OAuth/API path. Keep that provider intact; a future ChatGPT website capability is a separate integration.

## Architecture and contract

Keep a model-capable service a web service. Detect model support from the complete set of standardized model Actions with valid input/output schemas. No `modelProvider` field, capability version field, new service kind, or parallel service runtime is needed. Selecting the service in the model picker enables its use as a provider.

The host derives new provider identities from service identities and uses existing repository conflict resolution. A service cannot claim another provider's identity through arbitrary manifest text. Retain the four existing provider IDs through host-owned compatibility mappings.

| Standard Action | Input | Result |
| --- | --- | --- |
| `listModels` | None | Stable model IDs, labels, supported modalities/options, limits when known, and streaming/cancellation capabilities |
| `startModelGeneration` | Model ID, structured messages, supported options, attachment references | Generation ID and submission state |
| `readModelGeneration` | Generation ID, event cursor, bounded wait | Ordered events, next cursor, and generation state |
| `cancelModelGeneration` | Generation ID | Confirmed cancellation, requested but unconfirmed, already finished, or unsupported |

Reuse `getSignInUrl` and `getSignInState`. Validate exact standard schemas and handler parity. Preserve an existing incompatible ordinary `listModels` Action as `listWebsiteModels` when adding the standard contract; keep its behavior and output shape available to ordinary service callers.

Declaring a reserved model-generation Action requires the complete, compatible model Action set; incomplete or incompatible sets produce validation errors. An ordinary `listModels` Action alone does not opt a service into model support. Existing ordinary services remain valid. Introduce explicit contract versioning only when a concrete compatibility requirement warrants it.

Events support text snapshots initially, explicit completion, and typed failures. Final-only websites emit one text snapshot and completion. Reads are repeatable and retain terminal results for a bounded period so a lost response does not lose the answer. Cursor validation rejects gaps and out-of-order results.

Generation state is scoped to the live session. If its page or process is lost, report the interruption without automatically resubmitting. No durable generation checkpoints or task-resumption protocol are introduced.

Ox owns the Action-call envelope, schema validation, attachment access, and conversion to `AssistantEvent`. Services own website mechanics and website-specific message serialization. Pass attachments through bounded, Host-mediated references rather than embedding large binary payloads in Action arguments.

## Ordered work packages

### 1. Freeze and validate the contract

- Specify standard Actions, capability-detection rules, event schema, supported options, error categories, submission states, and compatibility behavior.
- Define page/process loss as an interrupted generation with no automatic resubmission.
- Keep the existing manifest structure. Add validation for standard model Actions alongside existing standard sign-in Actions.
- Update SDK validation, Swift Action validation and capability detection, compiler checks, and authoring documentation together. Reject incomplete or incompatible model contracts with actionable errors while preserving editable source data.

Acceptance: malformed and unsupported model capabilities cannot become selectable providers; existing ordinary services continue to validate unchanged.

### 2. Add generation lifecycle support

- Extend the existing scheduler through an owned generation session that pins the page and validated service revision across start/read/cancel.
- Ensure ordinary browsing, service navigation, and provider sign-in probes cannot take over a generation's page.
- Model submission separately from execution: not submitted, uncertain, or confirmed; running, completed, failed, or cancelled.
- Bound concurrent generations, event retention, read waits, attachment sizes, and idle cleanup. A cancel request must remain dispatchable while a read waits.
- Handle navigation, backgrounding, process loss, service reload, and removal explicitly. Source updates apply to new sessions; active sessions retain their revision or end visibly.
- Add structured logs linking generation, provider, source revision, submission outcome, and terminal state without recording reusable secrets.

Acceptance: lifecycle tests cover cancellation during polling, lost read responses, page loss, concurrent ordinary Actions, source reload, and cleanup.

### 3. Connect the generic provider and model picker

- Add `WebServiceModelProvider` implementing `ProviderClient` over the standard Actions.
- Discover model capabilities by checking the complete validated standard Action set in resolved, enabled service sources, without requiring attachment to an individual chat. Initialize discovery after service storage preparation to avoid registry/Host startup cycles.
- Refresh the provider registry when validated service sources change. Handle conflicts, disabling, and removal without silently switching a saved selection to a different model.
- Use the existing repository source selection for both ordinary Actions and model generation. Copying a built-in service to Local uses the existing copy/source-selection operation and creates no additional provider entry. Resolve any service conflict through the existing flow and preserve the provider identity when its selected source changes.
- Reuse service authentication and sign-in UI instead of maintaining a separate provider authentication cache.
- Exclude internal model Actions from ordinary agent tool discovery. Give model execution a scoped host role; preserve approvals for unrelated service Actions.
- Preserve existing provider/model IDs, chat selections, default models, and login data. Route any necessary persisted conversion through `StorageMigrator` and document the downgrade boundary.

Acceptance: a compatible installed service appears in the picker without site-specific Swift code; old chats and saved selections still resolve.

### 4. Prove one service, then migrate the four providers

- Start with Qwen to exercise model discovery, streaming, and attachments in one vertical slice, subject to account access on the user-selected simulator.
- Follow manage-services contracts for implementation and verification. For these four migrations, the user explicitly authorized Codex to author website behavior directly.
- Share site-specific helpers within each service between ordinary chat Actions and model Actions.
- Verify text, conversation context, supported attachments, model selection, Ox Action calls, cancellation semantics, and remote conversation identity.
- Include the verified source in the built-in repository as part of the approved migration, add sanitized regression coverage, and rebuild the built-in bundle.
- Migrate Kimi, Grok, and Claude one at a time. Keep site-specific Swift providers until each replacement passes its verification matrix, then remove their duplicate JavaScript and obsolete tests.

Acceptance: the four existing website providers work through the generic adapter with their verified capabilities preserved; native API/subscription providers remain available.

### 5. Verify the existing editing workflow

- Document the model capability and standard Actions in manage-services so an agent can edit model-capable services using the existing workflow.
- Keep built-in model-capable services read-only. Copy one to Local, resolve the duplicate through the existing service conflict flow, then edit it inside Ox, validate it, exercise it live, and Save through existing service operations.
- Verify that activation updates the generic provider for subsequent generations while preserving provider identity, sign-in data, and unrelated Local edits.
- Keep invalid drafts editable without replacing the active validated implementation.

Acceptance: an agent copies a built-in model service to Local, resolves the conflict, and edits it through manage-services. A new model request and ordinary Actions use the same selected, validated source without duplicate provider entries, site-specific Swift changes, or an app rebuild.

## Verification and release gates

- Contract fixtures: validation parity across TypeScript/Swift; complete-set detection; incomplete or incompatible model Actions; ordinary service compatibility, including an existing standalone `listModels` Action; model identity conflicts; unsupported modalities/options.
- Runtime tests: ordered cursors, terminal retention, cancel races, page ownership, source revision pinning, and interrupted generations without automatic resubmission.
- Upgrade fixtures from the actual predecessor representation: existing provider selections, default model, catalog overrides, Local Git state, and unchanged website sessions. Any migration change runs the required storage-migration simulator gate.
- Live iOS QA on an available `ox-qa-1` through `ox-qa-5` iOS 26 simulator, using `sim` to build/install/launch and `ox` for chats/logs. Exercise provider selection, sign-in, generation, ordinary service Actions, and Local editing and activation. Preserve screenshots outside the repository and restore changed simulator settings.
- Run `bun run typecheck` and relevant contract, runtime, provider, and sanitized service replay tests. Run `bun run check:system-skills` after workflow edits, `bun run check:localizations` immediately after localization changes, and `bun run build:services` after service/compiler changes.
- Consult Apple WebKit documentation during the lifecycle implementation. Review changed lines and complexity before each commit; follow the repository's App Store version and commit-message requirements.

## Scope boundaries

The first release delivers the four existing web providers through editable services and one generic adapter. Automatic repair, fallback model selection, recovery Actions, durable generation checkpoints, and interrupted-task resumption are out of scope. Adding ChatGPT website support is a separate live-authored integration after the generic path is proven.

# Ox agent runtime

`apps/ios/Ox/Host/Agent` is Ox's provider-neutral agent runtime. Ox owns its APIs,
state model, tests, and evolution. Pi is a useful semantic reference for agent-loop
and provider behavior, but it is not a dependency, compatibility target, or source
tree to mirror:

- <https://github.com/earendil-works/pi/tree/main/packages/agent>
- <https://github.com/earendil-works/pi/tree/main/packages/ai>

Prefer the simplest design for Ox even when it intentionally differs from Pi.
An upstream abstraction belongs here only when it solves a concrete Ox problem.

## Runtime boundary

`Agent/` owns reusable model execution behavior:

- agent state, turns, queues, cancellation, and lifecycle events,
- request-local context transformation before provider serialization,
- model-aware modality adaptation in `ModelAdapters/` without changing native model metadata,
- tool declaration, validation, scheduling, execution, and results,
- provider-neutral messages and streamed response assembly,
- supported provider transports, authentication seams, and replay metadata,
- context estimation, compaction, and overflow recovery.

The application layer owns chat presentation, transcript persistence, services,
artifacts, user handoffs, and app configuration. Dependencies point from `Chat`
and app orchestration into `Agent`; the runtime must not depend on those layers.

`ProviderRegistry` stays outside this directory because selected defaults, regional
selection, and catalog lookup are application configuration. `LLM/Providers/`
owns provider composition while `LLM/Transports/` owns shared wire protocols.

## Semantic reference map

Use this map to locate comparable behavior during an upstream audit. It is not a
parity checklist.

| Pi agent | Ox runtime |
| --- | --- |
| `src/agent.ts` | `Agent.swift` |
| `src/agent-loop.ts` | `AgentRunner.swift` |
| `src/types.ts` | `AgentEvent.swift`, `AgentContext.swift`, `AgentRunConfig.swift`, `AgentTurnHooks.swift`, `AgentMessages.swift` |
| tool types and execution helpers | `Tools/` |
| pending message queues | `Queue/` |
| relevant compaction semantics | `AgentCompactor.swift` |

| Pi AI | Ox runtime |
| --- | --- |
| `src/types.ts` model/message/context types | `LLM/ProviderClient.swift`, `LLM/AssistantEvent.swift`, `AgentMessages.swift`, `AgentContext.swift` |
| `src/utils/event-stream.ts` | `LLM/AssistantEvent.swift`, `LLM/LLMStreaming.swift` |
| supported `src/api/*` adapters | `LLM/Transports/` wire protocols and `LLM/Providers/` composition |
| supported provider auth seams | `LLM/Auth/` and provider-specific auth |
| `src/api/transform-messages.ts` replay behavior | provider adapters; add a shared transform only when multiple local consumers need it |
| tool declaration conversion | `Tools/AgentTool.swift`, `LLM/LLMStreaming.swift` |

Pi's harness does not map to the runtime. `Chat.swift`, `ProfileRepository`, and the
rest of Ox's application layer implement their own product-specific behavior.

## Upstream relevance policy

Always review upstream changes that can affect an Ox-owned behavior:

1. tool safety and terminal control flow,
2. loop lifecycle, cancellation, queue draining, and settlement,
3. stream assembly, terminal events, errors, and usage accounting,
4. replay metadata and request encoding for providers Ox ships,
5. context estimation, compaction, overflow recovery, and cache isolation,
6. model metadata that Ox exposes to users.

Ignore by default unless Ox gains a matching product requirement:

- Node execution environments and coding-agent filesystem or shell tools,
- Pi harness, session repositories, SQLite/JSONL stores, search, and session trees,
- prompt-template and filesystem skill discovery,
- remote LLM proxy and bundler compatibility layers,
- dynamic or deferred tools introduced through transcript metadata,
- image-generation registries,
- environment-variable credential discovery,
- unsupported provider adapters and their model catalogs.

Do not add an API merely because Pi added one. Require a concrete Ox call site,
provider contract, production failure, or regression test.

## Intentional Ox design

- Built-in providers disable reasoning where supported and use the lowest documented effort otherwise; provider adapters translate that policy into native request fields.
- Ox chat and session persistence stay outside the agent runtime.
- `Agent` is an actor with asynchronous commands and immutable snapshots; observation and presentation mirrors stay in the chat layer.
- Ox tools default to sequential execution because they mutate UI or session state and may wait on the user.
- Filesystem reads return complete text to JavaScript unless the caller explicitly requests a shorter read; file-size safeguards are independent of model context. `ChatJavaScriptTool` caps combined console output at the last 2,000 lines or 50 KiB per execution, independent of model context, then appends a recovery notice. Do not add truncation in message constructors or provider serializers. Oversized console output is retained by the loaded chat and recovered through `ox.output.read`; its reference is temporary and must not be represented as a durable artifact. `AgentContextBudget` is used only for compaction, which can summarize an earlier portion of an ongoing turn without separating tool calls from their results.
- Swift uses `AsyncStream`, `AsyncThrowingStream`, `Task`, and actor isolation rather than JavaScript stream interfaces and `AbortSignal`.
- Provider authentication and account UI are app-specific even when protocol seams live under `LLM/Auth`.
- `ProviderModel` is the provider-owned execution profile selected through the provider-neutral `ProviderClient` interface; it separates stable selection IDs from wire IDs and represents execution variants without leaking request fields into the picker.
- Model adapters transform ephemeral request copies for the current model snapshot while persisted messages retain their original attachments; native model modalities remain provider-owned facts.
- Every artifact contributes the same canonical `Attached artifact` reference; adapters place derived analysis immediately after that reference when replacing media a model cannot consume.
- `ProviderModel` retains reasoning support, provider-specific effort strings in lowest-to-highest order, and typed input and output modalities from the catalog; adapters choose the first supported effort while the agent runner rejects incompatible attachment history locally before compaction or provider streaming.
- Built-in model metadata comes from one checked-in provider-model manifest refreshed from models.dev and resolved to Ox's curated global and China selections; `ProviderRegistry` decodes its `ProviderModel` values directly while transport, authentication, regional policy, and provider wiring remain app-owned.
- Built-in providers absent from models.dev keep the smallest official-documentation-backed model set in `CuratedProviderModels.swift` until upstream supplies compatible catalog metadata.
- Provider adapters classify raw failures before the agent loop handles context overflow or chat presents user-facing errors.
- Remote model execution uses one of four explicit wire protocols: OpenAI Responses, OpenAI Chat Completions, Anthropic Messages, or Gemini GenerateContent.
- Ox's provider collection is static app wiring rather than a reusable provider collection.
- Responses adapters retain provider response IDs, raw stop reasons, item IDs, and opaque text or reasoning signatures for stateless replay.
- Each provider owns one composition entry point for identity, endpoints, authentication, regional behavior, and protocol-specific policy; complex authentication may remain in provider-owned supporting files.
- OpenAI-compatible provider profiles select cache-key routing and output-token fields while the shared transport owns serialization and usage normalization.
- Subscription-key providers with OpenAI-compatible endpoints reuse the shared chat adapter while retaining plan-specific provider identities, endpoints, and credential labels.
- Providers whose global and China endpoints use separate accounts retain one picker identity while storing region-specific credentials.
- Amazon Bedrock composes Mantle Responses and Anthropic Messages transports behind one provider, using Bedrock API-key authentication and provider-namespaced wire model IDs.
- Built-in providers expose the curated bundled catalog immediately and validate credentials or entitlements on the first real request instead of querying inconsistent runtime model-list endpoints.
- Custom OpenAI-compatible providers still discover models from their configured endpoint because Ox has no bundled catalog for them; models reported without tool calling are excluded.

## Change checklist

For a relevant upstream behavior, inspect the smallest corresponding Ox path:

1. `AgentRunner.swift` for loop semantics, turn boundaries, queue order, stop conditions, and tool-result ordering.
2. `Agent.swift` for state reduction, queue APIs, abort settlement, and public runtime methods.
3. `Tools/` for tool hooks, scheduling, validation, result mutation, and terminal dispositions.
4. `AgentEvent.swift` and `LLM/AssistantEvent.swift` for lifecycle and streaming events.
5. `AgentRunConfig.swift` and `AgentContext.swift` for turn configuration and snapshots.
6. `AgentMessages.swift` for provider-neutral message and content shapes.
7. `AgentCompactor.swift` for context estimation and compaction behavior.
8. `LLM/ProviderClient.swift` and `LLM/LLMStreaming.swift` for stream contracts and assembly.
9. Only the concrete provider and authentication adapters affected by the change.
10. `Chat.swift` and persistence only when metadata or product orchestration must cross the runtime boundary.

Implement the smallest Ox-native behavior and verify it through Ox's tests.
Upstream source and tests are evidence, not an implementation specification.

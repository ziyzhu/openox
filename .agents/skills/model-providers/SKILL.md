---
name: model-providers
description: Research, add, review, or update Ox model-provider integrations and human-facing provider metadata, including official product sites, account or API portals, and Global or China account boundaries. Use for changes under Host/Agent/LLM/Providers, ModelProviders registry or catalog, or provider documentation; do not use for generic model evaluation or agent-loop behavior.
---

# Model Providers

Keep every provider integration easy to discover without turning documentation into a second runtime specification.

## Ownership

- Provider references own official product and developer links, the purpose of human-facing account portals, and account or geography distinctions that affect setup.
- Provider Swift files own exact client identifiers, display names, picker regions, endpoint URLs, portal deep links, credentials, transport selection, and request policy.
- Model-capable web services own website authentication, submission, upload, completion, and model discovery behavior in `repositories/builtin/web/<domain>/actions.js`. They expose the standard model Actions described by the built-in `manage-services` skill; `WebServiceModelProvider.swift` owns their shared adapter and compatibility identities.
- `apps/ios/Ox/Host/ModelProviders/provider-models.json` owns bundled model metadata sourced from models.dev.
- `CuratedProviderModels.swift` owns the smallest reviewed model set for providers absent from the shared catalog.

Do not copy API base URLs, request headers, model IDs, context limits, reasoning controls, cache behavior, or other executable configuration into references. Link to the owning code instead. A reference may state the human meaning of a region or portal when that context is needed to make a correct product decision.

## Workflow

Read the matching provider reference before changing or reviewing an integration. Verify unstable metadata against first-party provider sources. Treat the provider source and catalog as authoritative when documentation disagrees, then update the reference only where its human-facing context is stale.

When adding a built-in provider:

1. Give it a provider-owned composition file under `apps/ios/Ox/Host/Agent/LLM/Providers`.
2. Reuse a transport from `LLM/Transports` when its wire protocol already exists.
3. Add a focused reference named for the provider composition entry point.
4. Add the reference to the routing list below.
5. Keep account-region boundaries explicit, especially when Global and China use different credentials or portals.

Test signed-out and expired-session behavior with synthetic fixtures or an isolated session. Do not remove authentication from a live signed-in website-client request: its unauthorized-response handler can clear the user’s session even when the request itself is read-only. Verify the signed-out-to-signed-in transition across a separate handoff page. Sign-in probes must read fresh shared state and avoid website-client handlers that clear credentials on an unauthorized response; a successful check on an already authenticated page is insufficient.

When adding attachment support, check bundled and discovered model capabilities, provider validation, user messages, Action results, and history together. Verify that the model can read a synthetic image or document through the real upload path; an upload ID alone is insufficient. For composer-driven providers, reacquire the editor after file processing and verify native editor state before submission; an enabled Send button can reflect attachments while the prompt is still uncommitted. Preserve pre-existing website drafts.

For built-in model web services, use reviewed 128×128 `favicon.png` sources and let the service build generate the OpenOx CloudFront URL; remove third-party `faviconUrl` overrides. Audit the opaque central 96×96 area and light/dark rendering at 20 px, upload through the existing service-assets deployment workflow, and verify the anonymous hosted response matches the source. See [icon provenance](../../../docs/MODEL_WEB_PROVIDER_ICONS.md). Use the resolved service and shared `ServiceAvatar` in the web-provider picker so it honors the same icon URL and loading rules as Services. Local user-authored services retain their verified public icon URLs.

Run `bun run typecheck` after provider or catalog changes. Build and exercise the iOS app with `sim` when runtime Swift changes.

## Updating models

`bun run update:llms` refreshes metadata from models.dev for the sources already selected in `provider-models.json`; it does not discover or select newer releases. For a model refresh, review each selected provider's catalog for supported successors, update the source selections and any affected ID or display-name overrides, then run the command. Preserve intentional token caps and regional or subscription account boundaries. Do not infer a reseller's availability from the upstream vendor's catalog.

Keep the importer's capability and status checks intact when a selected model is deprecated or missing. Confirm a supported replacement or remove the unavailable selection. Verify changed request requirements against provider documentation, including whether reasoning can be disabled. Review model-specific adaptive-thinking and reasoning-replay lists alongside catalog changes; these lists must match wire IDs, including provider prefixes.

## Provider references

- [Amazon Bedrock](references/amazon-bedrock.md)
- [Anthropic](references/anthropic.md)
- [ChatGPT](references/chatgpt.md)
- [Claude Website](references/claude-website.md)
- [Custom OpenAI-compatible](references/custom-openai-compatible.md)
- [DeepSeek](references/deepseek.md)
- [Gemini](references/gemini.md)
- [GitHub Copilot](references/github-copilot.md)
- [Kimi](references/kimi.md)
- [MiniMax](references/minimax.md)
- [Mistral](references/mistral.md)
- [ModelScope](references/modelscope.md)
- [BytePlus ModelArk and Volcengine Ark](references/modelark.md)
- [OpenAI API](references/openai.md)
- [OpenCode Go](references/opencode-go.md)
- [OpenRouter](references/openrouter.md)
- [Qwen and Qwen Coding Plan](references/qwen.md)
- [SiliconFlow](references/siliconflow.md)
- [StepFun](references/stepfun.md)
- [Tencent TokenHub](references/tencent-tokenhub.md)
- [xAI](references/xai.md)
- [Z.AI and GLM Coding Plan](references/zai.md)

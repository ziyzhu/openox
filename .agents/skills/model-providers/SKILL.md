---
name: model-providers
description: Research, add, review, or update Ox model-provider integrations and human-facing provider metadata, including official product sites, account or API portals, and Global or China account boundaries. Use for changes under Host/Agent/LLM/Providers, ModelProviders registry or catalog, or provider documentation; do not use for generic model evaluation or agent-loop behavior.
---

# Model Providers

Keep every provider integration easy to discover without turning documentation into a second runtime specification.

## Ownership

- Provider references own official product and developer links, the purpose of human-facing account portals, and account or geography distinctions that affect setup.
- Provider Swift files own exact client identifiers, display names, picker regions, endpoint URLs, portal deep links, credentials, transport selection, and request policy.
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

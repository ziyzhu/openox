---
name: providers
description: Drive Ox's manage-providers workflow, review and promote verified provider/model updates into bundled defaults, or maintain native provider transports and authentication. Use for development changes to Ox's provider catalog or runtime; routine on-device management belongs to Ox's built-in manage-providers skill, not this desktop workflow.
---

# Ox Providers

Ox owns provider and model management through the built-in `manage-providers` skill. This desktop workflow exercises that same path, ships reviewed defaults, and maintains runtime support that cannot be expressed as provider data. Do not maintain a second catalog-management playbook here.

## Drive Ox

Read the `sim-cli` and `ox-cli` skills. Follow simulator ownership and data-preservation rules; use the selected device and matching Host endpoint.

1. Establish whether the request is for an on-device change, bundled defaults, or native runtime support. On-device management does not authorize publication.
2. Drive a real Ox chat through `skills/manage-providers/SKILL.md`. Let Ox inspect, research, propose, validate, save, and verify supported catalog changes. Do not substitute direct catalog edits for this workflow.
3. Observe chat history, provider state, and structured logs. Report missing capabilities or unclear boundaries; improve the shared skill or runtime and exercise the workflow again.
4. Preserve sanitized verification evidence outside the repository. State separately which definitions were validated, which models were exercised, and which checks remain unperformed.

## Promote bundled defaults

Only promote when the user requests a bundled update. Read the matching provider reference below and verify unstable metadata against first-party sources.

- Export the verified definitions with `ox.provider.get` through the chat VM. Exclude credentials, personal configuration, unrelated overrides, and account-specific availability.
- Review the focused diff against `ox.provider.default` and the owning source files. Preserve provider identities, regional/subscription boundaries, intentional token caps, and request policy.
- Translate the reviewed changes into the existing bundled sources; do not introduce a second runtime catalog. `provider-models.json` owns models.dev selections and metadata; `CuratedProviderModels.swift` owns reviewed models absent from that catalog. Provider Swift composition owns exact endpoints, credentials, transport selection, and request options.
- For models.dev-backed changes, update source selections and affected ID/display-name overrides before `bun run update:llms`. The command refreshes selected sources; it does not discover successors. Keep capability/status checks intact and review model-specific thinking/reasoning lists against wire IDs, including provider prefixes.
- Rebuild and verify bundled behavior without saved overrides masking it, using an isolated test setup. Never delete a user's override merely to test defaults: provider deletion also clears credentials.

## Maintain native support

Read [native integrations](references/native-integrations.md) and the matching provider reference before changing native composition, transport, authentication, website adapters, or artwork. These changes belong in code, not an on-device skill. New model-capable website behavior belongs to the built-in `evolve` workflow and shared `WebServiceModelProvider`, not a site-specific Swift provider.

Run `bun run typecheck` after provider or catalog changes. Build and exercise runtime Swift changes with `sim`. Do not commit unless requested.

## Provider references

References own official product/developer links and human-facing account or geography context. Executable configuration stays in code or the catalog; do not copy API URLs, headers, model IDs, limits, reasoning controls, or caching policy into references.

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

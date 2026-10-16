---
name: providers
description: Drive Ox's manage-providers workflow, review and promote verified provider/model updates into bundled defaults, or maintain native provider transports and authentication. Use for development changes to Ox's provider catalog or runtime; routine on-device management belongs to Ox's built-in provider guidance, not this desktop workflow.
---

# Ox Providers

Ox owns provider and model management through `skills/manage-providers/SKILL.md`. This desktop workflow exercises that same path, ships reviewed defaults, and maintains runtime support that cannot be expressed as provider data. Do not maintain a second catalog-management playbook here.

## Drive Ox

Read the `ios-simulator` and `ox-cli` skills. Follow simulator ownership and data-preservation rules; use the selected device and matching Host endpoint.

1. Establish whether the request is for an on-device change, bundled defaults, or native runtime support. On-device management does not authorize publication.
2. Drive a real Ox conversation through `skills/manage-providers/SKILL.md`. Let Ox inspect, research, propose, validate, save, and verify supported catalog changes. Do not substitute direct catalog edits for this workflow.
3. Observe conversation history, provider state, and structured logs. Report missing capabilities or unclear boundaries; improve the shared guidance or runtime and exercise the workflow again.
4. Preserve sanitized verification evidence outside the repository. State separately which definitions were validated, which models were exercised, and which checks remain unperformed.

## Promote bundled defaults

Only promote when the user requests a bundled update. Read the matching provider reference below and verify unstable metadata against first-party sources.

- Export the verified definitions with `ox.provider.get` through the conversation VM. Exclude credentials, personal configuration, unrelated overrides, and account-specific availability.
- Review the focused diff against `ox.provider.default` and the owning source files. Preserve provider identities, regional/subscription boundaries, intentional token caps, and request policy.
- Translate the reviewed changes into `providers.json`; do not introduce a second runtime catalog. Each entry owns a provider's definition, presentation, legacy identifiers, and `discovery` settings. Pinned `models` keep existing picker IDs, aliases, Fast variants, and intentional caps; new models arrive through runtime discovery, so do not pin a model only because it is new.
- `discovery` names the list `format`, the models.dev `catalog` that fills capabilities for ID-only lists, and `rules` that match model IDs with `*` to exclude entries, cap output tokens, or set per-model options. Run `bun run update:llms` after changing catalogs to refresh `provider-catalog.json`; it snapshots every active text model with tool calls for each referenced catalog.
- Swift owns only behavior that data cannot express: transports, custom adapter authentication, and OAuth accounts.
- Rebuild and verify bundled behavior without saved overrides masking it, using an isolated test setup. Never delete a user's override merely to test defaults: provider deletion also clears credentials.

## Maintain native support

Read [native integrations](references/native-integrations.md) and the matching provider reference before changing native composition, transport, authentication, or artwork. These changes belong in code, not on-device guidance. Providers use API transports, including API-backed subscription/OAuth accounts. Websites are ordinary services authored through Ox's built-in `evolve` System skill, never providers or browser bridges for the agent loop.

Run `bun run typecheck` after provider or catalog changes. Build runtime Swift changes with `xcodebuild`, install/launch with `simctl`, and exercise the UI with `idb`. Do not commit unless requested.

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

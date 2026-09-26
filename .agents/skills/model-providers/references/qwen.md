# Qwen and Qwen Coding Plan

## Official destinations

- Global website: [Alibaba Cloud Model Studio](https://www.alibabacloud.com/en/product/model-studio)
- Global developer documentation: [Model Studio documentation](https://www.alibabacloud.com/help/en/model-studio/)
- China website: [Alibaba Cloud Model Studio in China](https://bailian.console.aliyun.com/)
- China developer documentation: [Model Studio documentation in China](https://help.aliyun.com/zh/model-studio/)
- China free-quota policy: [New-user quotas and stop-at-quota behavior](https://help.aliyun.com/zh/model-studio/new-free-quota)
- Qwen Code authentication status: [Authentication](https://github.com/QwenLM/qwen-code/blob/main/docs/users/configuration/auth.md)
- Account management: Model Studio API keys or Coding Plan subscription keys on the regional platform. Current deep links belong in the provider source.

## Ox account placement

Ox exposes Qwen API access and Qwen Coding Plan in Global and China. Each product keeps distinct credentials, and each product's Global and China credentials are also separate. Do not collapse these account boundaries because their APIs are protocol-compatible.

Qwen Website is a separate Global chat option. It uses the signed-in Ox browser session for `chat.qwen.ai`, not a Model Studio or Coding Plan key. Ox can load text-chat models reported by the consumer website and select one for its next website conversation; the Default choice follows the website's current selection. User attachments and live Ox Action media use the website uploader. Image and PDF support follows the selected model; Load models refreshes previously saved capabilities. Its page-owned request client and completion stream can change independently of the developer API. Ox Action calls through this website are prompt-emulated and require the same schema validation and approval boundary as other Ox Actions. Use the shared Ox-specific envelope markers; generic tool-call markers can be consumed by the website’s own tool handler.

The China general API is a first-run trial option because new Model Studio accounts receive time-limited model quotas. Qwen OAuth is not an Ox onboarding option; its free tier was discontinued in 2026. Verified users must enable the provider's stop-at-quota setting to prevent paid overage.

## Runtime sources

- Provider composition and regional account mapping: [QwenProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/QwenProvider.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)
- Website adapter: [QwenWebsiteProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/QwenWebsiteProvider.swift)

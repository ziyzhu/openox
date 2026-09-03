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

The China general API is a first-run trial option because new Model Studio accounts receive time-limited model quotas. Qwen OAuth is not an Ox onboarding option; its free tier was discontinued in 2026. Verified users must enable the provider's stop-at-quota setting to prevent paid overage.

## Runtime sources

- Provider composition and regional account mapping: [QwenProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/QwenProvider.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

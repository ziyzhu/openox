# Qwen and Qwen Coding Plan

## Official destinations

- Global website: [Alibaba Cloud Model Studio](https://www.alibabacloud.com/en/product/model-studio)
- Global developer documentation: [Model Studio documentation](https://www.alibabacloud.com/help/en/model-studio/)
- China website: [Alibaba Cloud Model Studio in China](https://bailian.console.aliyun.com/)
- China developer documentation: [Model Studio documentation in China](https://help.aliyun.com/zh/model-studio/)
- Account management: Model Studio API keys or Coding Plan subscription keys on the regional platform. Current deep links belong in the provider source.

## Ox account placement

Ox exposes Qwen API access and Qwen Coding Plan in Global and China. Each product keeps distinct credentials, and each product's Global and China credentials are also separate. Do not collapse these account boundaries because their APIs are protocol-compatible.

## Runtime sources

- Provider composition and regional account mapping: [QwenProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/QwenProvider.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

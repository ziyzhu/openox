# Z.AI and GLM Coding Plan

## Official destinations

- Global website: [Z.AI](https://z.ai/)
- Global developer documentation: [Z.AI Developer Documentation](https://docs.z.ai/)
- China website and developer platform: [BigModel Open Platform](https://open.bigmodel.cn/)
- Account management: general API keys or GLM Coding Plan subscriptions on the regional platform. Current deep links belong in the provider source.

## Ox account placement

Ox exposes the general Z.AI API and Z.AI Coding Plan in Global and China. Each product keeps distinct credentials, and each product's Global and China credentials are also separate. The Coding Plan is a supported-tools product, not a general-API alias.

## Runtime sources

- Provider composition and regional account mapping: [ZAIProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/ZAIProvider.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

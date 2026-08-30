# xAI

## Official destinations

- Website: [xAI](https://x.ai/)
- Developer documentation: [xAI API documentation](https://docs.x.ai/)
- Account management: xAI Console API keys or the supported xAI subscription sign-in. The current Ox API-key deep link belongs in the provider source.

## Ox account placement

Ox presents xAI in Global. One provider identity can authenticate through the supported subscription account or an API key; preserve that fallback behavior in code.

## Runtime sources

- Provider composition: [XAIProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAIProvider.swift)
- OAuth: [XAIOAuth.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAIOAuth.swift)
- Account state: [XAISubscriptionAccount.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAISubscriptionAccount.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

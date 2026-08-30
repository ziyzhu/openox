# DeepSeek

## Official destinations

- Website: [DeepSeek](https://www.deepseek.com/)
- Developer documentation: [DeepSeek API Docs](https://api-docs.deepseek.com/)
- Account management: DeepSeek Platform API keys. The current Ox deep link belongs in the provider source.

## Ox account placement

Ox presents DeepSeek in Global and China under one provider identity. The current integration intentionally shares the credential identity between those picker regions; do not introduce separate regional accounts without confirming the product requirement.

## Runtime sources

- Provider composition: [DeepSeekProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/DeepSeekProvider.swift)
- Shared wire behavior: [OpenAICompatibleProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/OpenAICompatibleProvider.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

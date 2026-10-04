# OpenAI API

## Official destinations

- Website: [OpenAI API](https://openai.com/api/)
- Developer documentation: [OpenAI API documentation](https://platform.openai.com/docs/overview)
- Account management: OpenAI Platform API keys. The current Ox deep link belongs in the provider source.

## Ox account placement

Ox presents the OpenAI API in Global. Keep this API-key provider separate from the ChatGPT subscription provider even though both use the OpenAI Responses transport.

## Runtime sources

- Provider composition: [OpenAIProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/OpenAIProvider.swift)
- Wire protocol: [OpenAIResponsesTransport.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Transports/OpenAIResponsesTransport.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

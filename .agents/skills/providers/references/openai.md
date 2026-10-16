# OpenAI API

## Official destinations

- Website: [OpenAI API](https://openai.com/api/)
- Developer documentation: [OpenAI API documentation](https://platform.openai.com/docs/overview)
- Account management: OpenAI Platform API keys. The current Ox deep link belongs in the provider source.

## Ox account placement

Ox presents the OpenAI API in Global. Keep this API-key provider separate from the ChatGPT subscription provider even though both use the OpenAI Responses transport.

## Runtime sources

- Definition, presentation, and model discovery: [providers.json](../../../../apps/shared/Host/ModelProviders/providers.json)
- Wire protocol: [OpenAIResponsesTransport.swift](../../../../apps/shared/Host/Agent/LLM/Transports/OpenAIResponsesTransport.swift)

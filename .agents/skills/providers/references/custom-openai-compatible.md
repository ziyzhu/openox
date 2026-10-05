# Custom OpenAI-compatible providers

## Human-facing destination

There is no shared official website or account portal. The user supplies a server URL and, optionally, a bearer credential. Never describe a custom server as belonging to OpenAI merely because it implements an OpenAI-compatible protocol.

## Ox account placement

Ox makes a configured custom provider available in Global and China because it is user-hosted. The selected picker region does not determine where that server processes data.

## Runtime sources

- Persisted definition and model discovery: [CustomLLMProvider.swift](../../../../apps/ios/Ox/Host/ModelProviders/CustomLLMProvider.swift)
- Shared composition: [OpenAICompatibleProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/OpenAICompatibleProvider.swift)
- Wire protocol: [OpenAIChatTransport.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Transports/OpenAIChatTransport.swift)

Keep validation, normalization, discovery behavior, inference-location semantics, and credential handling in code rather than documenting assumed server behavior here.

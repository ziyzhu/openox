# ChatGPT

## Official destinations

- Website: [Codex in ChatGPT](https://chatgpt.com/codex)
- Product information: [OpenAI Codex](https://openai.com/codex/)
- Help: [Codex collection in the OpenAI Help Center](https://help.openai.com/en/collections/14937370-codex)
- Account management: ChatGPT subscription and account settings. This integration does not use an OpenAI Platform API key.

## Ox account placement

Ox presents ChatGPT in Global. Treat it as a subscription-backed provider identity separate from the OpenAI API provider, even though both reuse the OpenAI Responses transport.

## Runtime sources

- Provider composition: [ChatGPTProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/ChatGPT/ChatGPTProvider.swift)
- OAuth: [ChatGPTOAuth.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/ChatGPT/ChatGPTOAuth.swift)
- Account state: [ChatGPTSubscriptionAccount.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/ChatGPT/ChatGPTSubscriptionAccount.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

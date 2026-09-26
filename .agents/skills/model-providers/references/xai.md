# xAI

## Official destinations

- Website: [xAI](https://x.ai/)
- Developer documentation: [xAI API documentation](https://docs.x.ai/)
- Account management: xAI Console API keys or the supported xAI subscription sign-in. The current Ox API-key deep link belongs in the provider source.

## Ox account placement

Ox presents xAI in Global. One provider identity can authenticate through the supported subscription account or an API key; preserve that fallback behavior in code.

Grok Website is a separate Global chat option with text, image, and PDF input using the signed-in Ox browser session for `grok.com`. User and Action attachments go through the native composer. Its website conversation stream is distinct from the xAI API and subscription Responses transport. Ox Action calls through this website are prompt-emulated and require schema validation and Ox approval.

## Runtime sources

- Provider composition: [XAIProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAIProvider.swift)
- OAuth: [XAIOAuth.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAIOAuth.swift)
- Account state: [XAISubscriptionAccount.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAISubscriptionAccount.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)
- Website provider: [grok.com/actions.js](../../../../repositories/builtin/web/grok.com/actions.js)

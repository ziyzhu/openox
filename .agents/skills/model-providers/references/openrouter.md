# OpenRouter

## Official destinations

- Website: [OpenRouter](https://openrouter.ai/)
- Developer documentation: [OpenRouter quickstart](https://openrouter.ai/docs/quickstart)
- OAuth documentation: [OpenRouter OAuth PKCE](https://openrouter.ai/docs/guides/overview/auth/oauth)
- Free Models Router: [OpenRouter free router](https://openrouter.ai/docs/guides/routing/routers/free-router)
- Account management: [OpenRouter API keys](https://openrouter.ai/settings/keys)

## Ox account placement

Ox presents OpenRouter in Global. Users can connect their OpenRouter account with OAuth PKCE or paste an API key. The OAuth exchange creates a user-controlled OpenRouter API key stored in the keychain. The Free Models Router is the onboarding default and dynamically chooses a compatible zero-token-cost model; its availability and rate limits can vary. Other OpenRouter models may charge the user's account. OpenRouter is the provider identity even when the selected model originates from another model vendor.

## Runtime sources

- Provider composition and routing policy: [OpenRouterProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/OpenRouter/OpenRouterProvider.swift)
- OAuth endpoints and exchange: [OpenRouterOAuth.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/OpenRouter/OpenRouterOAuth.swift)
- OAuth account storage: [OpenRouterSubscriptionAccount.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/OpenRouter/OpenRouterSubscriptionAccount.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

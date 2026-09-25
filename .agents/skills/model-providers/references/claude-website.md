# Claude Website

## Official destinations

- Website and account sign-in: [Claude](https://claude.ai/)
- API product: [Anthropic API](https://www.anthropic.com/api)

## Ox account placement

Ox presents Claude Website in Global. It uses the consumer website session inside Ox and is separate from the Anthropic API-key provider. The website model currently accepts text conversation and checks completed answers against Claude's conversation record. Ox Action calls use an experimental prompt-based envelope.

## Runtime sources

- Website provider: [ClaudeWebsiteProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/ClaudeWebsiteProvider.swift)
- Provider definition: [BundledProviderDefinitions.swift](../../../../apps/ios/Ox/Host/ModelProviders/BundledProviderDefinitions.swift)

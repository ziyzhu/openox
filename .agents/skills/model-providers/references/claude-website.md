# Claude Website

## Official destinations

- Website and account sign-in: [Claude](https://claude.ai/)
- API product: [Anthropic API](https://www.anthropic.com/api)

## Ox account placement

Ox presents Claude Website in Global. It uses the consumer website session inside Ox and is separate from the Anthropic API-key provider. The website model accepts text, image, and PDF input and checks completed answers against Claude's conversation record. User and Action attachments go through its native file input. Existing website drafts must be cleared by the user before Ox submits. Ox Action calls use an experimental prompt-based envelope.

## Runtime sources

- Website provider: [claude.ai/actions.js](../../../../repositories/builtin/web/claude.ai/actions.js)
- Provider definition: [BundledProviderDefinitions.swift](../../../../apps/ios/Ox/Host/ModelProviders/BundledProviderDefinitions.swift)

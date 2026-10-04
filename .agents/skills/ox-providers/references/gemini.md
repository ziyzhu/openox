# Gemini

## Official destinations

- Website: [Google AI for Developers](https://ai.google.dev/)
- Developer documentation: [Gemini API documentation](https://ai.google.dev/gemini-api/docs)
- Billing and tiers: [Gemini API billing](https://ai.google.dev/gemini-api/docs/billing)
- Model pricing and free-tier data use: [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- Account management: Google AI Studio API keys. The current Ox deep link belongs in the provider source.

## Ox account placement

Ox presents the Gemini API in Global. New accounts begin on Google's free tier, and the models Ox currently presents have free input and output usage subject to limits. Google states that free-tier content may be used to improve its products, while paid-tier content is not. Document Google Cloud Vertex AI separately if Ox adds it; it has different account, region, and authentication semantics.

## Website account

The Gemini web service can also supply the website's default text model through the shared web-service adapter. It uses the signed-in Gemini website session and is separate from Google AI Studio API credentials. Model selection, streaming, and attachments are advertised only when verified by the service.

## Runtime sources

- Website model and ordinary Actions: [Gemini service](../../../../repositories/builtin/web/gemini.google.com/actions.js)
- Provider and Gemini GenerateContent implementation: [GeminiProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/GeminiProvider.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

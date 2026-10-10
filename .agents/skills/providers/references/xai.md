# xAI

## Official destinations

- Website: [xAI](https://x.ai/)
- Developer documentation: [xAI API documentation](https://docs.x.ai/)
- Account management: xAI Console API keys or the supported xAI subscription sign-in. The current Ox API-key deep link belongs in the provider source.

## Ox account placement

Ox presents xAI in Global. One provider identity can authenticate through the supported subscription account or an API key; preserve that fallback behavior in code.

The current subscription flow uses the same OAuth client identity as Pi's xAI flow. Verify an OpenOx registration before changing or extending this sign-in flow.

Grok Website remains an ordinary service using the signed-in browser session for `grok.com`. It receives explicit service inputs and cannot run the Ox agent model. Its website session stays separate from xAI API and subscription Responses credentials.

## Runtime sources

- Provider composition: [XAIProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAIProvider.swift)
- OAuth: [XAIOAuth.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAIOAuth.swift)
- Account state: [XAISubscriptionAccount.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/XAI/XAISubscriptionAccount.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)
- Website service: [grok.com/actions.js](../../../../apps/ios/Ox/Resources/OxServices.bundle/web/grok.com/actions.js)

## Implementation comparison

- [Pi's xAI OAuth flow](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/xai.ts) is a reference for reviewing Ox's subscription sign-in.

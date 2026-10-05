# Kimi

## Official destinations

- Global website: [Kimi International](https://www.kimi.ai/)
- Global developer platform: [Kimi Open Platform](https://platform.kimi.ai/)
- China website: [Kimi China](https://www.kimi.com/)
- Regional sign-in guidance: [Kimi account regions](https://www.kimi.com/code/docs/kimi-code-desktop/getting-started.html)
- Account management: the Kimi global platform or Moonshot China platform, according to the Ox picker region. Current deep links belong in the provider source.

## Ox account placement

Ox presents the Kimi API in Global and China. These are separate service surfaces with region-specific credentials; never silently reuse one region's credential for the other. Kimi For Coding is a separate subscription choice in Global.

The Kimi Website provider is a separate China chat option with text, image, and PDF input. It uses the signed-in Ox browser session for `www.kimi.com` and does not use the Kimi Open Platform API key. Kimi's regional sign-in guidance identifies `kimi.com` as mainland China and `kimi.ai` as international. An international website integration needs its own verified session and service support; do not move an existing China session to the international domain. User attachments and live Ox Action media use the signed-in website upload flow. Its website RPC is distinct from the official developer API and may change independently. The website chat service remains a separate Ox service.

## Runtime sources

- Provider composition and regional account mapping: [KimiProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/KimiProvider.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)
- Kimi For Coding models: [CuratedProviderModels.swift](../../../../apps/ios/Ox/Host/ModelProviders/CuratedProviderModels.swift)
- Website provider: [www.kimi.com/actions.js](../../../../apps/ios/Ox/Resources/OxServices.bundle/web/www.kimi.com/actions.js)

## Implementation comparison

- [Pi's Kimi Coding OAuth flow](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/kimi-coding.ts) supplies the device-code client identity and OAuth contract. Ox sends its own request identity to Kimi Coding. [Pi requested its own allowlist entry](https://github.com/MoonshotAI/kimi-code/issues/2185); [Kimi's guidelines](https://www.kimi.com/code/docs/en/kimi-code/community-guidelines.html) prohibit spoofing another client's identity. [Kimi's model guidance](https://www.kimi.com/code/docs/en/kimi-code/models.html) lists the coding-plan models and their account-tier limits.

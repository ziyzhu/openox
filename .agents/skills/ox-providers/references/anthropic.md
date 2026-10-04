# Anthropic

## Official destinations

- Website: [Claude API](https://www.anthropic.com/api)
- Developer documentation: [Anthropic API documentation](https://docs.anthropic.com/)
- API authentication: [Claude Platform authentication](https://platform.claude.com/docs/en/manage-claude/authentication)
- Account management: Anthropic Console API keys. The current Ox deep link belongs in the provider source.

## Ox account placement

Ox presents the Anthropic API and Claude Pro/Max in Global as separate choices. The API-key product remains distinct from a consumer Claude subscription.

Claude Pro/Max follows Pi's OAuth flow using its public CLI client identity and Claude Code request identity. Claude Website uses the user's browser session. Claude Platform's registered iOS app authentication uses App Attest and bills the developer's API workspace, so it does not provide consumer subscription access. [Anthropic's subscription guidance](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account) directs third-party applications to API-key authentication and prohibits routing their traffic against subscription limits. This flow may be refused or charged to usage credits.

## Runtime sources

- Provider composition: [AnthropicProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/AnthropicProvider.swift)
- Wire protocol: [AnthropicMessagesTransport.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Transports/AnthropicMessagesTransport.swift)
- Models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

## Implementation comparison

- [Pi's Claude subscription OAuth flow](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/anthropic.ts) supplies the current client identity and OAuth contract. [Pi's Anthropic Messages transport](https://github.com/earendil-works/pi/blob/main/packages/ai/src/api/anthropic-messages.ts) supplies the Claude Code request identity. Ox adapts its callback handling for iOS.

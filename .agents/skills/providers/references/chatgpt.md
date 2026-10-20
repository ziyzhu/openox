# ChatGPT

## Official destinations

- Website: [Sign in with ChatGPT](https://learn.chatgpt.com/docs/sign-in-with-chatgpt)
- Developer contract: [Open-source registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- Product information: [OpenAI Codex](https://openai.com/codex/)
- Help: [Codex collection in the OpenAI Help Center](https://help.openai.com/en/collections/14937370-codex)
- Account management: ChatGPT subscription and account settings. This integration does not use an OpenAI Platform API key.

## Ox account placement

Ox presents ChatGPT in Global. Treat it as a subscription-backed provider identity separate from the OpenAI API provider, even though both reuse the OpenAI Responses transport.

Ox uses OpenOx-named dynamic registration for the open-source, locally hosted ChatGPT plan flow. Identity and plan-use consent are separate; only validated identity and granted inference scopes establish a connection. Keep the issued registration tied to its user/workspace and use the public Responses API, never borrowed Codex client IDs or ChatGPT backend endpoints. Paid or remotely hosted offerings require separate eligibility review.

The new credential record is isolated from predecessor Codex credentials; existing users sign in again. Retain old credentials without forwarding them to the public API. Verify actual predecessor/changed-build storage compatibility before release.

## Runtime sources

- Request authentication: [ChatGPTProvider.swift](../../../../apps/shared/Host/Agent/LLM/Providers/ChatGPT/ChatGPTProvider.swift)
- OAuth: [ChatGPTOAuth.swift](../../../../apps/shared/Host/Agent/LLM/Providers/ChatGPT/ChatGPTOAuth.swift)
- Account state: [ChatGPTSubscriptionAccount.swift](../../../../apps/shared/Host/Agent/LLM/Providers/ChatGPT/ChatGPTSubscriptionAccount.swift)
- Definition, presentation, and model discovery: [providers.json](../../../../apps/shared/Host/ModelProviders/providers.json)

## Implementation comparison

- Follow the first-party open-source contract above. Do not substitute historical Codex OAuth implementations for this registration and token contract.

# GitHub Copilot

## Official destinations

- Website: [GitHub Copilot](https://github.com/features/copilot)
- Developer documentation: [GitHub Copilot documentation](https://docs.github.com/en/copilot)
- Account management: GitHub Copilot settings and the user's personal or organization entitlement. This integration does not use a generic model-provider API key.

## Ox account placement

Ox presents GitHub Copilot in Global. Model availability is entitlement-dependent and may differ by account, organization policy, or product surface.

The provider picker uses the official GitHub Copilot extension mark, hosted on OpenOx CloudFront. It must remain distinct from the general GitHub site favicon.

## Runtime sources

- Request authentication: [GitHubCopilotProvider.swift](../../../../apps/shared/Host/Agent/LLM/Providers/GitHubCopilot/GitHubCopilotProvider.swift)
- OAuth: [GitHubCopilotOAuth.swift](../../../../apps/shared/Host/Agent/LLM/Providers/GitHubCopilot/GitHubCopilotOAuth.swift)
- Account state: [GitHubCopilotSubscriptionAccount.swift](../../../../apps/shared/Host/Agent/LLM/Providers/GitHubCopilot/GitHubCopilotSubscriptionAccount.swift)
- Definition, presentation, and model discovery: [providers.json](../../../../apps/shared/Host/ModelProviders/providers.json)

## Implementation comparison

- [Pi's GitHub Copilot OAuth flow](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/oauth/github-copilot.ts) is a reference for reviewing Ox's device sign-in.

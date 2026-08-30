# GitHub Copilot

## Official destinations

- Website: [GitHub Copilot](https://github.com/features/copilot)
- Developer documentation: [GitHub Copilot documentation](https://docs.github.com/en/copilot)
- Account management: GitHub Copilot settings and the user's personal or organization entitlement. This integration does not use a generic model-provider API key.

## Ox account placement

Ox presents GitHub Copilot in Global. Model availability is entitlement-dependent and may differ by account, organization policy, or product surface.

## Runtime sources

- Provider composition and entitlement filtering: [GitHubCopilotProvider.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/GitHubCopilot/GitHubCopilotProvider.swift)
- OAuth: [GitHubCopilotOAuth.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/GitHubCopilot/GitHubCopilotOAuth.swift)
- Account state: [GitHubCopilotSubscriptionAccount.swift](../../../../apps/ios/Ox/Host/Agent/LLM/Providers/GitHubCopilot/GitHubCopilotSubscriptionAccount.swift)
- Curated candidate models: [provider-models.json](../../../../apps/ios/Ox/Host/ModelProviders/provider-models.json)

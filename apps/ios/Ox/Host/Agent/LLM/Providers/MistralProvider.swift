import Foundation

nonisolated enum MistralProvider {
    static let profile = OpenAICompatibleProvider(
        id: "mistral",
        displayName: RegionalValue("Mistral"),
        endpoint: regionalURL("https://api.mistral.ai/v1"),
        reasoningControl: .effort(.none),
        website: regionalURL("https://console.mistral.ai/api-keys"),
        authNotice: "Mistral Free mode includes limited API usage without a credit card. Usage and rate limits apply.",
        gettingStartedOffer: ProviderGettingStartedOffer(
            summary: "API key · Free mode",
            priority: 2
        )
    )
}

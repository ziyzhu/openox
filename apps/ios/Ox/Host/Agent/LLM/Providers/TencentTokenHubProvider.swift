import Foundation

nonisolated enum TencentTokenHubProvider {
    static let profile = OpenAICompatibleProvider(
        id: "tencent-tokenhub",
        displayName: RegionalValue("Tencent TokenHub"),
        regions: [.china],
        endpoint: regionalURL("https://tokenhub.tencentmaas.com/v1"),
        reasoningReplayModelIDs: ["hy3"],
        website: regionalURL("https://console.cloud.tencent.com/tokenhub/apikey"),
        authNotice: "New accounts can claim 1M free tokens per language model for 90 days. Calls stop at the limit unless you enable postpaid billing.",
        gettingStartedOffer: ProviderGettingStartedOffer(
            summary: "API key · 1M-token trial",
            priority: 3,
            regions: [.china]
        )
    )
}

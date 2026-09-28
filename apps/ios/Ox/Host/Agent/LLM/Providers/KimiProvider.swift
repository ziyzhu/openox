import Foundation

nonisolated enum KimiProvider {
    static let codingClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let codingBaseURL = URL(string: "https://api.kimi.com/coding")!

    static let profile = OpenAICompatibleProvider(
        id: "kimi",
        displayName: RegionalValue("Kimi API"),
        regions: [.global, .china],
        endpoint: regionalURL("https://api.moonshot.ai/v1", overrides: [.china: "https://api.moonshot.cn/v1"]),
        regionalCredentials: true,
        promptCacheRouting: .requestBody,
        maxTokensField: .maxCompletionTokens,
        reasoningReplayModelIDs: ["kimi-k3"],
        reasoningControl: .effort(.low),
        iconURL: regionalURL("https://openox.ai/assets/services/model-providers/kimi/favicon.png"),
        website: regionalURL("https://platform.kimi.ai/console/api-keys", overrides: [.china: "https://platform.moonshot.cn/console/api-keys"])
    )

    static func codingClient(models: [ProviderModel]) -> AnthropicMessagesTransport {
        AnthropicMessagesTransport(
            id: "kimi-coding",
            displayName: "Kimi For Coding",
            models: models,
            endpoint: codingBaseURL.appendingPathComponent("messages"),
            iconURL: URL(string: "https://openox.ai/assets/services/model-providers/kimi/favicon.png"),
            website: URL(string: "https://www.kimi.com/code"),
            usesAPIKey: false,
            acceptsAPIKey: false
        )
    }
}

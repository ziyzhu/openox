import Foundation

nonisolated enum KimiProvider {
    static let profile = OpenAICompatibleProvider(
        id: "kimi",
        displayName: RegionalValue("Kimi"),
        regions: [.global, .china],
        endpoint: regionalURL("https://api.moonshot.ai/v1", overrides: [.china: "https://api.moonshot.cn/v1"]),
        regionalCredentials: true,
        promptCacheRouting: .requestBody,
        maxTokensField: .maxCompletionTokens,
        reasoningReplayModelIDs: ["kimi-k3"],
        reasoningControl: .effort(.low),
        website: regionalURL("https://platform.kimi.ai/console/api-keys", overrides: [.china: "https://platform.moonshot.cn/console/api-keys"])
    )
}

import Foundation

nonisolated enum MiniMaxProvider {
    static let tokenPlan = OpenAICompatibleProvider(
        id: "minimax-token-plan",
        displayName: RegionalValue("MiniMax Token Plan"),
        regions: [.global, .china],
        endpoint: regionalURL("https://api.minimax.io/v1", overrides: [.china: "https://api.minimaxi.com/v1"]),
        credentialKind: .subscriptionKey,
        regionalCredentials: true,
        extraBody: ["reasoning_split": .bool(true)],
        maxTokensField: .maxCompletionTokens,
        reasoningReplayModelIDs: ["MiniMax-M3"],
        reasoningControl: .disabled(.thinking),
        website: regionalURL("https://platform.minimax.io/subscribe/coding-plan", overrides: [.china: "https://platform.minimaxi.com/subscribe/coding-plan"])
    )

    static let api = OpenAICompatibleProvider(
        id: "minimax",
        displayName: RegionalValue("MiniMax"),
        regions: [.china],
        endpoint: regionalURL("https://api.minimax.io/v1", overrides: [.china: "https://api.minimaxi.com/v1"]),
        regionalCredentials: true,
        extraBody: ["reasoning_split": .bool(true)],
        maxTokensField: .maxCompletionTokens,
        reasoningReplayModelIDs: ["MiniMax-M3"],
        reasoningControl: .disabled(.thinking),
        website: regionalURL("https://platform.minimax.io/user-center/basic-information/interface-key", overrides: [.china: "https://platform.minimaxi.com/user-center/basic-information/interface-key"])
    )
}

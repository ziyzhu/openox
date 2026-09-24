import Foundation

nonisolated enum DeepSeekProvider {
    static let profile = OpenAICompatibleProvider(
        id: "deepseek",
        displayName: RegionalValue("DeepSeek"),
        regions: [.global, .china],
        endpoint: regionalURL("https://api.deepseek.com/v1"),
        reasoningReplayModelIDs: ["deepseek-flash", "deepseek-v4-pro"],
        reasoningControl: .disabled(.thinking),
        website: regionalURL("https://platform.deepseek.com/api_keys")
    )
}

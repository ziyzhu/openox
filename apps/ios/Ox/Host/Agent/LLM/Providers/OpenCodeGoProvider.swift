import Foundation

nonisolated enum OpenCodeGoProvider {
    static let profile = OpenAICompatibleProvider(
        id: "opencode-go",
        displayName: RegionalValue("OpenCode Go"),
        endpoint: regionalURL("https://opencode.ai/zen/go/v1"),
        credentialKind: .subscriptionKey,
        reasoningReplayModelIDs: ["deepseek-v4-flash", "deepseek-v4-pro", "kimi-k3", "glm-5.2", "ox-alpha-free"],
        reasoningControl: .providerDefault,
        website: regionalURL("https://opencode.ai/go")
    )
}

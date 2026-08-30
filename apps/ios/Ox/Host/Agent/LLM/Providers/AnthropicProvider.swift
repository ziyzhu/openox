import Foundation

nonisolated enum AnthropicProvider {
    static func client(models: [ProviderModel]) -> AnthropicMessagesTransport {
        AnthropicMessagesTransport(
            id: "anthropic",
            displayName: "Anthropic",
            models: models,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            website: URL(string: "https://console.anthropic.com/settings/keys"),
            adaptiveThinkingModelIDs: ["claude-sonnet-5", "claude-opus-5", "claude-fable-5"]
        )
    }
}

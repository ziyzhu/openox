import Foundation

nonisolated enum AnthropicProvider {
    static let subscriptionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let subscriptionRedirectURI = "http://localhost:53692/callback"
    static let subscriptionSystemIdentity = "You are Claude Code, Anthropic's official CLI for Claude."
    static let subscriptionScopes = [
        "org:create_api_key", "user:profile", "user:inference", "user:sessions:claude_code",
        "user:mcp_servers", "user:file_upload",
    ]

    static func client(models: [ProviderModel]) -> AnthropicMessagesTransport {
        AnthropicMessagesTransport(
            id: "anthropic",
            displayName: "Anthropic API",
            models: models,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            iconURL: URL(string: "https://openox.ai/assets/services/model-providers/anthropic/favicon.png"),
            website: URL(string: "https://console.anthropic.com/settings/keys"),
            adaptiveThinkingModelIDs: ["claude-sonnet-5", "claude-opus-5-5", "claude-fable-5-1"]
        )
    }

    static func subscriptionClient(models: [ProviderModel]) -> AnthropicMessagesTransport {
        AnthropicMessagesTransport(
            id: "claude-subscription",
            displayName: "Claude Pro/Max",
            models: models,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            iconURL: URL(string: "https://openox.ai/assets/services/model-providers/anthropic/favicon.png"),
            website: URL(string: "https://claude.ai/upgrade"),
            usesAPIKey: false,
            acceptsAPIKey: false,
            adaptiveThinkingModelIDs: ["claude-sonnet-5", "claude-opus-5-5", "claude-fable-5-1"],
            beta: ["claude-code-20250219", "oauth-2025-04-20"],
            systemIdentity: subscriptionSystemIdentity
        )
    }
}

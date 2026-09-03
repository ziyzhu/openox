import Foundation

nonisolated struct OpenRouterAuth: OpenAIChatTransportAuth {
    var canRefresh: Bool { false }

    func resolve(forceRefresh _: Bool) async throws -> OpenAIChatEndpoint {
        let apiKey = if OpenRouterSubscriptionAccount.shared.isSignedIn {
            try OpenRouterSubscriptionAccount.shared.apiKey()
        } else if let apiKey = Credentials.key(for: "openrouter") {
            apiKey
        } else {
            throw OpenAIAuthError.missingAPIKey("openrouter")
        }
        return OpenAIChatEndpoint(
            baseURL: OpenRouterOAuth.apiBaseURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "HTTP-Referer": "https://github.com/ziyzhu/openox",
                "X-OpenRouter-Title": "Ox",
            ]
        )
    }
}

nonisolated enum OpenRouterProvider {
    private static let reasoningReplayModelIDs: Set<String> = [
        "stealth/ox-alpha",
        "anthropic/claude-sonnet-5",
        "openai/gpt-5.6-terra",
        "google/gemini-3.7-flash",
        "deepseek/deepseek-v4-flash-0731",
        "qwen/qwen3.8-max",
        "moonshotai/kimi-k3",
        "z-ai/glm-5.2",
    ]

    static func client(models: [ProviderModel]) -> OpenAIChatTransport {
        OpenAIChatTransport(
            id: "openrouter",
            displayName: "OpenRouter",
            models: models,
            regions: [.global],
            auth: OpenRouterAuth(),
            subscriptionAccount: OpenRouterSubscriptionAccount.shared,
            extraBody: ["provider": .object(["sort": .string("latency")])],
            reasoningReplayModelIDs: reasoningReplayModelIDs,
            reasoningControl: .reasoningObject,
            website: URL(string: "https://openrouter.ai/settings/keys"),
            authNotice: "The Free Models Router automatically chooses a compatible model at no token charge. Availability and rate limits can vary. Other OpenRouter models may charge your account.",
            gettingStartedOffer: ProviderGettingStartedOffer(
                summary: "OAuth · Free Models Router",
                priority: 0
            ),
            diagnosticsEndpoint: OpenRouterOAuth.apiBaseURL
        )
    }
}

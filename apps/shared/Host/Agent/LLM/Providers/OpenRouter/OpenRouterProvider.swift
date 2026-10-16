import Foundation

nonisolated struct OpenRouterAuth: OpenAITransportAuth {
    var canRefresh: Bool { false }

    func resolve(forceRefresh _: Bool) async throws -> OpenAIEndpoint {
        let apiKey = if OpenRouterSubscriptionAccount.shared.isSignedIn {
            try OpenRouterSubscriptionAccount.shared.apiKey()
        } else if let apiKey = Credentials.key(for: "openrouter") {
            apiKey
        } else {
            throw OpenAIAuthError.missingAPIKey("openrouter")
        }
        return OpenAIEndpoint(
            url: OpenRouterOAuth.apiBaseURL.appendingPathComponent("chat/completions"),
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "HTTP-Referer": "https://github.com/ziyzhu/openox",
                "X-OpenRouter-Title": "Ox",
            ]
        )
    }
}

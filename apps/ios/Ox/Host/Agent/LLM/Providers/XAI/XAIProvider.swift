import Foundation

nonisolated struct XAIResponsesAuth: OpenAIResponsesTransportAuth {
    var canRefresh: Bool { XAISubscriptionAccount.shared.isSignedIn }
    func resolve(forceRefresh: Bool) async throws -> OpenAIResponsesEndpoint {
        let token: String
        if XAISubscriptionAccount.shared.isSignedIn {
            token = try await XAISubscriptionAccount.shared.validToken(forceRefresh: forceRefresh)
        } else if let key = Credentials.key(for: "xai") {
            token = key
        } else {
            throw OpenAIAuthError.missingAPIKey("xai")
        }
        var url = XAIOAuth.responsesBaseURL
        url.appendPathComponent("responses")
        return OpenAIResponsesEndpoint(
            url: url,
            headers: ["Authorization": "Bearer \(token)", "User-Agent": "Ox/iOS"]
        )
    }
}

nonisolated enum XAIProvider {
    static func client(models: [ProviderModel]) -> OpenAIResponsesTransport {
        OpenAIResponsesTransport(
            id: "xai",
            displayName: "xAI",
            models: models,
            website: URL(string: "https://console.x.ai/team/default/api-keys"),
            subscriptionAccount: XAISubscriptionAccount.shared,
            auth: XAIResponsesAuth(),
            reasoningEffort: .low
        )
    }
}

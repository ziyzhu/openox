import Foundation

nonisolated struct XAIResponsesAuth: OpenAIResponsesAuth {
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

nonisolated enum XAIClient {
    static func make() -> OpenAIResponsesClient {
        OpenAIResponsesClient(
            id: "xai",
            displayName: "xAI",
            models: ModelsDevCatalog.models(for: "xai"),
            website: URL(string: "https://console.x.ai/team/default/api-keys"),
            subscriptionAccount: XAISubscriptionAccount.shared,
            auth: XAIResponsesAuth(),
            reasoningEffort: .low
        )
    }
}

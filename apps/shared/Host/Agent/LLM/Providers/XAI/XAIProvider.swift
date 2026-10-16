import Foundation

nonisolated struct XAIResponsesAuth: OpenAITransportAuth {
    var canRefresh: Bool { XAISubscriptionAccount.shared.isSignedIn }
    func resolve(forceRefresh: Bool) async throws -> OpenAIEndpoint {
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
        return OpenAIEndpoint(
            url: url,
            headers: ["Authorization": "Bearer \(token)", "User-Agent": "Ox/iOS"]
        )
    }
}

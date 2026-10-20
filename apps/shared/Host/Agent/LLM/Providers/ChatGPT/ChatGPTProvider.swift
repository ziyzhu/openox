import Foundation

nonisolated struct ChatGPTResponsesAuth: OpenAITransportAuth {
    var canRefresh: Bool { true }

    func resolve(forceRefresh: Bool) async throws -> OpenAIEndpoint {
        let access = try await ChatGPTSubscriptionAccount.shared.validToken(forceRefresh: forceRefresh)
        return OpenAIEndpoint(url: ChatGPTOAuth.responsesURL, headers: ["Authorization": "Bearer \(access)"])
    }
}

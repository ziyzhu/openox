import Foundation

nonisolated struct GitHubCopilotResponsesAuth: OpenAITransportAuth {
    var canRefresh: Bool { false }
    func resolve(forceRefresh: Bool) async throws -> OpenAIEndpoint {
        let accessToken = try GitHubCopilotSubscriptionAccount.shared.accessToken()
        var url = GitHubCopilotOAuth.apiURL
        url.appendPathComponent("responses")
        return OpenAIEndpoint(
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "User-Agent": "Ox/iOS",
                "Openai-Intent": "conversation-edits",
                "X-GitHub-Api-Version": GitHubCopilotOAuth.apiVersion,
                "x-initiator": "user",
            ]
        )
    }
}

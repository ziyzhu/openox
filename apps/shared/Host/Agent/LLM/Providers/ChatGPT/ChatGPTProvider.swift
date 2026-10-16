import Foundation

nonisolated struct ChatGPTResponsesAuth: OpenAITransportAuth {
    private static let installationID: String = {
        let key = "chatgpt.installationId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    var canRefresh: Bool { true }
    func resolve(forceRefresh: Bool) async throws -> OpenAIEndpoint {
        let (access, accountID) = try await ChatGPTSubscriptionAccount.shared.validToken(forceRefresh: forceRefresh)
        guard !accountID.isEmpty else { throw ChatGPTAuthError(message: "Missing ChatGPT account id") }
        return OpenAIEndpoint(
            url: ChatGPTOAuth.responsesURL,
            headers: [
                "Authorization": "Bearer \(access)",
                "ChatGPT-Account-Id": accountID,
                "OpenAI-Beta": "responses=experimental",
                "originator": ChatGPTOAuth.originator,
                "x-codex-installation-id": Self.installationID,
                "User-Agent": "codex_cli_rs/0.0.0 (Ox; iOS)",
            ]
        )
    }
}

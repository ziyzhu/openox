import Foundation

nonisolated struct ChatGPTResponsesAuth: OpenAIResponsesAuth {
    private static let installationID: String = {
        let key = "chatgpt.installationId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    var canRefresh: Bool { true }
    func resolve(forceRefresh: Bool) async throws -> OpenAIResponsesEndpoint {
        let (access, accountID) = try await ChatGPTSubscriptionAccount.shared.validToken(forceRefresh: forceRefresh)
        guard !accountID.isEmpty else { throw ChatGPTAuthError(message: "Missing ChatGPT account id") }
        return OpenAIResponsesEndpoint(
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

struct ChatGPTResponsesClient: LLMClient {
    private let client: OpenAIResponsesClient

    init(models: [ProviderModel]) {
        client = OpenAIResponsesClient(
            id: "chatgpt",
            displayName: "ChatGPT",
            models: models,
            website: URL(string: "https://chatgpt.com/codex"),
            usesAPIKey: false,
            acceptsAPIKey: false,
            subscriptionAccount: ChatGPTSubscriptionAccount.shared,
            auth: ChatGPTResponsesAuth(),
            sessionHeaderName: "session-id",
            serviceTier: { model in
                model.variant == .fast ? "priority" : nil
            }
        )
    }

    var id: String { client.id }
    var displayName: String { client.displayName }
    var models: [ProviderModel] { client.models }
    var regions: Set<LLMRegion> { client.regions }
    var website: URL? { client.website }
    var usesAPIKey: Bool { client.usesAPIKey }
    var acceptsAPIKey: Bool { client.acceptsAPIKey }
    var credentialKind: LLMCredentialKind { client.credentialKind }
    var supportsTools: Bool { client.supportsTools }
    var subscriptionAccount: (any SubscriptionAccount)? { client.subscriptionAccount }
    var inferenceLocation: LLMInferenceLocation { client.inferenceLocation }
    var reasoningPolicy: LLMReasoningPolicy { client.reasoningPolicy }
    var protocolDiagnostics: LLMProtocolDiagnostics { client.protocolDiagnostics }
    func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { client.wireProtocol(for: model) }

    func stream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions
    ) -> AsyncThrowingStream<AssistantEvent, Error> {
        client.stream(model: model, systemPrompt: systemPrompt, messages: messages, tools: tools, options: options)
    }
}

import Foundation

nonisolated struct GitHubCopilotResponsesAuth: OpenAIResponsesAuth {
    var canRefresh: Bool { false }
    func resolve(forceRefresh: Bool) async throws -> OpenAIResponsesEndpoint {
        let accessToken = try GitHubCopilotSubscriptionAccount.shared.accessToken()
        var url = GitHubCopilotOAuth.apiURL
        url.appendPathComponent("responses")
        return OpenAIResponsesEndpoint(
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

nonisolated struct GitHubCopilotClient: LLMClient {
    private let client: OpenAIResponsesClient
    private let curatedModels: [ProviderModel]

    init(models: [ProviderModel]) {
        curatedModels = models
        client = OpenAIResponsesClient(
            id: "github-copilot",
            displayName: "GitHub Copilot",
            models: curatedModels,
            regions: [.global],
            website: URL(string: "https://github.com/features/copilot"),
            usesAPIKey: false,
            acceptsAPIKey: false,
            subscriptionAccount: GitHubCopilotSubscriptionAccount.shared,
            auth: GitHubCopilotResponsesAuth()
        )
    }

    var id: String { client.id }
    var displayName: String { client.displayName }
    var models: [ProviderModel] {
        guard let available = GitHubCopilotSubscriptionAccount.shared.cachedAvailableModelIDs else {
            return curatedModels
        }
        let compatible = curatedModels.filter { available.contains($0.wireID) }
        return compatible.isEmpty ? curatedModels : compatible
    }
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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let available = try await GitHubCopilotSubscriptionAccount.shared.availableModelIDs()
                    guard available.contains(model.wireID) else {
                        throw GitHubCopilotError(
                            message: "\(model.displayName) is not available for this GitHub Copilot account",
                            failureKind: .provider
                        )
                    }
                    for try await event in client.stream(
                        model: model,
                        systemPrompt: systemPrompt,
                        messages: messages,
                        tools: tools,
                        options: options
                    ) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

import Foundation

nonisolated struct AmazonBedrockProvider: ProviderClient {
    let id = "amazon-bedrock"
    let displayName = "Amazon Bedrock"
    let regions: Set<LLMRegion> = [.global]
    let website = URL(string: "https://console.aws.amazon.com/bedrock/home?region=us-east-1#/api-keys")
    let authNotice: String? = "Ox connects to Amazon Bedrock in US East (N. Virginia). Use a Bedrock API key that can access these models in us-east-1."
    let reasoningPolicy: LLMReasoningPolicy = .none
    let models: [ProviderModel]

    private let responses: OpenAIResponsesTransport
    private let messages: AnthropicMessagesTransport

    init(models: [ProviderModel]) {
        self.models = models
        let gptModels = models.filter { $0.wireID.hasPrefix("openai.") }
        let claudeModels = models.filter { $0.wireID.hasPrefix("anthropic.") }
        responses = OpenAIResponsesTransport(
            id: id,
            displayName: displayName,
            models: gptModels,
            regions: regions,
            website: website,
            authNotice: authNotice,
            auth: OpenAIResponsesAPIKeyAuth(
                clientID: id,
                baseURL: URL(string: "https://bedrock-mantle.us-east-1.api.aws/openai/v1")!
            )
        )
        messages = AnthropicMessagesTransport(
            id: id,
            displayName: displayName,
            models: claudeModels,
            endpoint: URL(string: "https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages")!,
            adaptiveThinkingModelIDs: ["claude-sonnet-5", "claude-opus-5", "claude-fable-5"]
        )
    }

    func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? {
        model.wireID.hasPrefix("anthropic.") ? .anthropicMessages : .openAIResponses
    }

    func stream(
        model: ProviderModel,
        systemPrompt: String?,
        messages history: [Message],
        tools: [any AgentTool],
        options: StreamOptions
    ) -> AsyncThrowingStream<AssistantEvent, Error> {
        if model.wireID.hasPrefix("anthropic.") {
            Log.network.info("Amazon Bedrock routing model=\(model.id) protocol=\(LLMWireProtocol.anthropicMessages.rawValue)")
            return messages.stream(model: model, systemPrompt: systemPrompt, messages: history, tools: tools, options: options)
        }
        Log.network.info("Amazon Bedrock routing model=\(model.id) protocol=\(LLMWireProtocol.openAIResponses.rawValue)")
        return responses.stream(model: model, systemPrompt: systemPrompt, messages: history, tools: tools, options: options)
    }

}

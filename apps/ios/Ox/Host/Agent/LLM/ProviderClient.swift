import Foundation

nonisolated public enum PromptCachePolicy: Sendable {
    case standard
    case disabled
}

nonisolated public enum LLMPreparationOutcome: String, Sendable {
    case unsupported
    case ready
    case unavailable
}

nonisolated public enum LLMReasoningPolicy: String, Sendable, Equatable {
    case none
    case minimal
    case low
    case providerDefault
    case unavailable
}

nonisolated public enum LLMReasoningEffort: String, Sendable, Equatable {
    case none
    case minimal
    case low

    var policy: LLMReasoningPolicy {
        switch self {
        case .none: .none
        case .minimal: .minimal
        case .low: .low
        }
    }
}

nonisolated public struct StreamOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var promptCachePolicy: PromptCachePolicy
    public var sessionID: String?
    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        promptCachePolicy: PromptCachePolicy = .standard,
        sessionID: String? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.promptCachePolicy = promptCachePolicy
        self.sessionID = sessionID
    }
}

nonisolated public enum LLMRegion: String, CaseIterable, Sendable, Codable, Hashable {
    case global
    case china

    public var displayName: String {
        switch self {
        case .global: return "Global"
        case .china: return "China"
        }
    }
}

nonisolated public enum LLMInferenceLocation: Sendable, Equatable {
    case remote
    case userHosted
    case onDevice
}

nonisolated public enum LLMFailureKind: String, Sendable, Codable, Equatable {
    case contextOverflow
    case rateLimited
    case network
    case authentication
    case unsupportedInput
    case provider
}

nonisolated public enum LLMWireProtocol: String, Sendable, Codable, Equatable {
    case openAIResponses = "openai-responses"
    case openAIChatCompletions = "openai-chat-completions"
    case anthropicMessages = "anthropic-messages"
    case geminiGenerateContent = "gemini-generate-content"
}

nonisolated public struct LLMProtocolDiagnostics: Sendable {
    public var promptCacheRouting: String?
    public var maxTokensField: String?
    public var endpoint: String?

    public init(promptCacheRouting: String? = nil, maxTokensField: String? = nil, endpoint: String? = nil) {
        self.promptCacheRouting = promptCacheRouting
        self.maxTokensField = maxTokensField
        self.endpoint = endpoint
    }
}

nonisolated public enum LLMCredentialKind: Sendable, Equatable {
    case apiKey
    case subscriptionKey
    case bearerToken

    public var name: String {
        switch self {
        case .apiKey: return "API key"
        case .subscriptionKey: return "Subscription key"
        case .bearerToken: return "Bearer token"
        }
    }
}

nonisolated public protocol ProviderClient: Sendable {
    var id: String { get }
    var displayName: String { get }
    var models: [ProviderModel] { get }
    var regions: Set<LLMRegion> { get }
    var website: URL? { get }
    var authNotice: String? { get }
    var usesAPIKey: Bool { get }
    var acceptsAPIKey: Bool { get }
    var credentialKind: LLMCredentialKind { get }
    var credentialID: String { get }
    var supportsTools: Bool { get }
    var subscriptionAccount: (any SubscriptionAccount)? { get }
    var inferenceLocation: LLMInferenceLocation { get }
    var reasoningPolicy: LLMReasoningPolicy { get }
    var protocolDiagnostics: LLMProtocolDiagnostics { get }

    func wireProtocol(for model: ProviderModel) -> LLMWireProtocol?

    func prepare(
        model: ProviderModel,
        systemPrompt: String?,
        tools: [any AgentTool]
    ) async -> LLMPreparationOutcome

    func stream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions
    ) -> AsyncThrowingStream<AssistantEvent, Error>
}

nonisolated extension ProviderClient {
    public var regions: Set<LLMRegion> { [.global, .china] }
    public var website: URL? { nil }
    public var authNotice: String? { nil }
    public var usesAPIKey: Bool { true }
    public var acceptsAPIKey: Bool { usesAPIKey }
    public var credentialKind: LLMCredentialKind { usesAPIKey ? .apiKey : .bearerToken }
    public var credentialID: String { id }
    public var supportsTools: Bool { true }
    public var inferenceLocation: LLMInferenceLocation { .remote }
    public var reasoningPolicy: LLMReasoningPolicy { .unavailable }
    public var protocolDiagnostics: LLMProtocolDiagnostics { LLMProtocolDiagnostics() }

    public func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { nil }

    public func prepare(
        model: ProviderModel,
        systemPrompt: String?,
        tools: [any AgentTool]
    ) async -> LLMPreparationOutcome {
        .unsupported
    }

    public func supportsTools(for model: ProviderModel) -> Bool {
        model.supportsTools ?? supportsTools
    }
}

nonisolated public protocol ProviderClientError: LocalizedError, Sendable {
    var message: String { get }
    var failureKind: LLMFailureKind { get }
}

nonisolated extension ProviderClientError {
    public var errorDescription: String? { message }
    public var failureKind: LLMFailureKind { llmFailureKind(message: message) }
}

nonisolated func llmFailureKind(statusCode: Int? = nil, message: String) -> LLMFailureKind {
    if statusCode == 401 || statusCode == 403 { return .authentication }
    if statusCode == 429 { return .rateLimited }
    let value = message.lowercased()
    let authentication = ["missing api key", "not signed in", "authorization", "authentication", "unauthorized", "forbidden"]
    if authentication.contains(where: value.contains) { return .authentication }
    let rateLimited = ["resource_exhausted", "rate limit", "too many requests", "exceeded your current quota", "quota is exhausted"]
    if rateLimited.contains(where: value.contains) { return .rateLimited }
    let contextOverflow = [
        "prompt is too long",
        "request_too_large",
        "input is too long for requested model",
        "exceeds the context window",
        "maximum context length",
        "maximum prompt length",
        "reduce the length of the messages",
        "maximum allowed input length",
        "exceeds the available context size",
        "greater than the context length",
        "context window exceeds limit",
        "exceeded model token limit",
        "configured context size",
        "model_context_window_exceeded",
        "prompt too long",
        "range of input length should be",
        "context_length_exceeded",
        "context length exceeded",
        "too many tokens",
        "token limit exceeded",
    ]
    if contextOverflow.contains(where: value.contains) { return .contextOverflow }
    let network = ["offline", "network connection", "not connected to the internet", "timed out", "cannot find host", "cannot connect to host"]
    if network.contains(where: value.contains) { return .network }
    return .provider
}

nonisolated func llmFailureKind(error: Error) -> LLMFailureKind {
    if let error = error as? any ProviderClientError { return error.failureKind }
    if error is URLError { return .network }
    return llmFailureKind(message: error.localizedDescription)
}

nonisolated extension ProviderClient {
    func streamingTask(
        model: ProviderModel,
        messages: [Message],
        run: @escaping (AsyncThrowingStream<AssistantEvent, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<AssistantEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let error = modelInputCompatibilityError(messages: messages, model: model) {
                        Log.agent.error("ProviderClient rejected unsupported input model=\(model.id) required=[\(requiredInputModalities(in: messages).map(\.rawValue).sorted().joined(separator: ","))] supported=[\(model.modalities.input.map(\.rawValue).sorted().joined(separator: ","))]")
                        throw error
                    }
                    try await run(continuation)
                } catch {
                    let aborted = Task.isCancelled
                    var msg = AssistantMessage(model: model.id)
                    msg.stopReason = aborted ? .aborted : .error
                    msg.errorMessage = aborted
                        ? "aborted"
                        : ((error as? ProviderClientError)?.message ?? error.localizedDescription)
                    if !aborted { msg.failureKind = llmFailureKind(error: error) }
                    continuation.yield(.failed(reason: aborted ? .aborted : .error, error: msg))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

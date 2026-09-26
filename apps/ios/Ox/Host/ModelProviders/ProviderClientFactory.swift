import Foundation

nonisolated struct ProviderPresentation: Sendable {
    var regions: Set<LLMRegion> = [.global, .china]
    var website: URL?
    var authNotice: String?
    var offer: ProviderGettingStartedOffer?
    var credentialKind: LLMCredentialKind = .apiKey
    var inferenceLocation: LLMInferenceLocation = .remote
}

nonisolated enum ProviderClientFactory {
    static func make(_ definition: ProviderDefinition, presentation: ProviderPresentation = .init()) throws -> any ProviderClient {
        let models = definition.models.map(\.runtimeModel)
        let options = definition.options
        let account: (any SubscriptionAccount)?
        let genericAccount: ProviderOAuthAccount?
        if definition.auth.kind == .oauth {
            let oauth = ProviderOAuthAccount(definition)
            account = oauth
            genericAccount = oauth
        } else {
            account = customAccount(definition.auth.adapter)
            genericAccount = nil
        }
        let authentication = ProviderRequestAuthentication(definition: definition, account: genericAccount)
        let native: any ProviderClient
        switch definition.api {
        case .web:
            try validateAdapter(definition)
            switch definition.id {
            case "kimi-web": native = KimiWebsiteProvider(models: models)
            case "qwen-web": native = QwenWebsiteProvider(models: models)
            case "grok-web": native = GrokWebsiteProvider(models: models)
            case "claude-web": native = ClaudeWebsiteProvider(models: models)
            default: throw RuntimeError.bridge("Unsupported web provider")
            }
        case .openAIChatCompletions:
            let auth: any OpenAIChatTransportAuth
            if definition.auth.kind == .custom { auth = try customChatAuth(definition) }
            else { auth = authentication }
            native = OpenAIChatTransport(
                id: definition.id, displayName: definition.name, models: models, regions: presentation.regions,
                auth: auth, usesAPIKey: definition.auth.kind == .bearer || definition.auth.kind == .apiKey,
                acceptsAPIKey: definition.auth.kind == .bearer || definition.auth.kind == .apiKey || definition.auth.adapter == "openrouter",
                credentialKind: presentation.credentialKind, credentialID: definition.credentialID,
                subscriptionAccount: account, extraBody: options?.extraBody ?? [:],
                cachesSystemPrompt: options?.cachesSystemPrompt ?? false,
                promptCacheRouting: OpenAIChatTransport.PromptCacheRouting(rawValue: options?.cacheRouting ?? "") ?? .sessionHeader,
                maxTokensField: OpenAIChatTransport.MaxTokensField(rawValue: options?.maxTokensField ?? "") ?? .maxTokens,
                reasoningReplayModelIDs: Set(definition.models.filter { $0.options?.replayReasoning == true }.map { $0.wireID ?? $0.id }),
                reasoningControl: reasoningControl(options), website: presentation.website,
                authNotice: presentation.authNotice, gettingStartedOffer: presentation.offer,
                inferenceLocation: presentation.inferenceLocation, diagnosticsEndpoint: definition.url
            )
        case .openAIResponses:
            let auth: any OpenAIResponsesTransportAuth
            if definition.auth.kind == .custom { auth = try customResponsesAuth(definition) }
            else { auth = authentication }
            let tiers = Dictionary(uniqueKeysWithValues: definition.models.compactMap { model in model.options?.serviceTier.map { (model.id, $0) } })
            native = OpenAIResponsesTransport(
                id: definition.id, displayName: definition.name, models: models, regions: presentation.regions,
                website: presentation.website, authNotice: presentation.authNotice,
                usesAPIKey: definition.auth.kind == .bearer || definition.auth.kind == .apiKey,
                acceptsAPIKey: definition.auth.kind == .bearer || definition.auth.kind == .apiKey || definition.auth.adapter == "xai",
                subscriptionAccount: account, auth: auth, sessionHeaderName: options?.sessionHeader ?? "x-session-id",
                extraBody: options?.extraBody ?? [:], reasoningEffort: LLMReasoningEffort(rawValue: options?.reasoningEffort ?? "") ?? .none,
                serviceTier: { tiers[$0.id] },
                streamingTransport: options?.streaming == "websocket-with-sse-fallback"
                    ? .webSocketWithServerSentEventsFallback(accountHeader: options?.accountHeader ?? "ChatGPT-Account-Id") : .serverSentEvents
            )
        case .anthropicMessages:
            native = AnthropicMessagesTransport(
                id: definition.id, displayName: definition.name, models: models,
                endpoint: definition.url.appendingPathComponent("messages"), regions: presentation.regions,
                website: presentation.website, credentialKind: presentation.credentialKind,
                credentialID: definition.credentialID,
                adaptiveThinkingModelIDs: Set(definition.models.filter { $0.options?.adaptiveThinking == true }.map { $0.wireID ?? $0.id }),
                requestAuthentication: authentication, version: options?.version ?? "2023-06-01",
                beta: options?.beta ?? [], extraBody: options?.extraBody ?? [:]
            )
        case .geminiGenerateContent:
            native = GeminiProvider(models: models, config: GeminiConfig(baseURL: definition.url),
                                    requestAuthentication: authentication, extraBody: options?.extraBody ?? [:])
        }
        return DefinedProviderClient(definition: definition, native: native, presentation: presentation, account: account)
    }

    static func customAccount(_ adapter: String?) -> (any SubscriptionAccount)? {
        switch adapter {
        case "chatgpt": ChatGPTSubscriptionAccount.shared
        case "github-copilot": GitHubCopilotSubscriptionAccount.shared
        case "openrouter": OpenRouterSubscriptionAccount.shared
        case "xai": XAISubscriptionAccount.shared
        default: nil
        }
    }

    static func validateAdapter(_ definition: ProviderDefinition) throws {
        if definition.api == .web {
            let registeredURL: URL? = switch definition.id {
            case "kimi-web": URL(string: "https://www.kimi.com/")!
            case "qwen-web": URL(string: "https://chat.qwen.ai/")!
            case "grok-web": URL(string: "https://grok.com/")!
            case "claude-web": URL(string: "https://claude.ai/")!
            default: nil
            }
            guard let registeredURL,
                  definition.url == registeredURL,
                  definition.auth.kind == .custom,
                  definition.auth.adapter == definition.id,
                  validWebsiteModels(definition),
                  definition.options == nil else {
                throw RuntimeError.bridge("Invalid website provider configuration")
            }
            return
        }
        guard definition.auth.kind == .custom else { return }
        let expected: (URL, LLMWireProtocol)?
        switch definition.auth.adapter {
        case "chatgpt": expected = (ChatGPTOAuth.responsesURL.deletingLastPathComponent(), .openAIResponses)
        case "github-copilot": expected = (GitHubCopilotOAuth.apiURL, .openAIResponses)
        case "openrouter": expected = (OpenRouterOAuth.apiBaseURL, .openAIChatCompletions)
        case "xai": expected = (XAIOAuth.responsesBaseURL, .openAIResponses)
        default: expected = nil
        }
        guard let expected, definition.id == definition.auth.adapter,
              definition.url == expected.0, definition.api == expected.1 else {
            throw RuntimeError.bridge("Invalid provider: custom adapter must use its registered identity, endpoint, and API format")
        }
    }

    private static func validWebsiteModels(_ definition: ProviderDefinition) -> Bool {
        guard definition.id == "qwen-web" else { return definition.models.map(\.id) == ["website-default"] }
        guard definition.models.first?.id == "website-default", definition.models.count <= 101 else { return false }
        return definition.models.dropFirst().allSatisfy {
            guard let wireID = $0.wireID, !wireID.isEmpty else { return false }
            let input = Set($0.input ?? [.text])
            guard input.contains(.text), input.isSubset(of: [.text, .image, .pdf]) else { return false }
            return $0 == ProviderDefinition.Model(QwenWebsiteProvider.model(id: wireID, name: $0.name, input: input))
        }
    }

    private static func customChatAuth(_ definition: ProviderDefinition) throws -> any OpenAIChatTransportAuth {
        try validateAdapter(definition)
        guard definition.auth.adapter == "openrouter" else { throw RuntimeError.bridge("Unsupported custom chat authentication") }
        return OpenRouterAuth()
    }

    private static func customResponsesAuth(_ definition: ProviderDefinition) throws -> any OpenAIResponsesTransportAuth {
        try validateAdapter(definition)
        switch definition.auth.adapter {
        case "chatgpt": return ChatGPTResponsesAuth()
        case "github-copilot": return GitHubCopilotResponsesAuth()
        case "xai": return XAIResponsesAuth()
        default: throw RuntimeError.bridge("Unsupported custom Responses authentication")
        }
    }

    static func reasoningControl(_ options: ProviderDefinition.Options?) -> OpenAIChatTransport.ReasoningControl {
        switch options?.reasoningFormat {
        case "reasoning_effort": .effort(LLMReasoningEffort(rawValue: options?.reasoningEffort ?? "") ?? .none)
        case "reasoning_object": .reasoningObject
        case "disable-reasoning": .disabled(.reasoning)
        case "disable-thinking": .disabled(.thinking)
        case "disable-chat-template": .disabled(.chatTemplate)
        case "disable-qwen": .disabled(.qwen)
        default: .providerDefault
        }
    }
}

nonisolated private struct DefinedProviderClient: ProviderClient {
    let definition: ProviderDefinition
    let native: any ProviderClient
    let presentation: ProviderPresentation
    let account: (any SubscriptionAccount)?

    var id: String { definition.id }
    var displayName: String { definition.name }
    var models: [ProviderModel] {
        if definition.api == .web { return native.models }
        let models = definition.models.map(\.runtimeModel)
        guard definition.auth.adapter == "github-copilot",
              let available = GitHubCopilotSubscriptionAccount.shared.cachedAvailableModelIDs else { return models }
        return models.filter { available.contains($0.wireID) }
    }
    var regions: Set<LLMRegion> { presentation.regions }
    var website: URL? { presentation.website }
    var authNotice: String? { presentation.authNotice }
    var gettingStartedOffer: ProviderGettingStartedOffer? { presentation.offer }
    var usesAPIKey: Bool { definition.auth.kind == .bearer || definition.auth.kind == .apiKey ? definition.auth.optional != true : false }
    var acceptsAPIKey: Bool { native.acceptsAPIKey }
    var credentialKind: LLMCredentialKind { definition.auth.kind == .bearer && presentation.inferenceLocation == .userHosted ? .bearerToken : presentation.credentialKind }
    var credentialID: String { definition.credentialID }
    var subscriptionAccount: (any SubscriptionAccount)? { account }
    var supportsTools: Bool { native.supportsTools }
    var inferenceLocation: LLMInferenceLocation { presentation.inferenceLocation }
    var reasoningPolicy: LLMReasoningPolicy { native.reasoningPolicy }
    var protocolDiagnostics: LLMProtocolDiagnostics { native.protocolDiagnostics }
    var canLoadModels: Bool { native.canLoadModels }

    func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { definition.api }

    func websiteSessionIsAuthenticated() async throws -> Bool? {
        try await native.websiteSessionIsAuthenticated()
    }

    func loadModels() async throws -> [ProviderModel] {
        try await native.loadModels()
    }

    func prepare(model: ProviderModel, systemPrompt: String?, tools: [any AgentTool]) async -> LLMPreparationOutcome {
        await native.prepare(model: model, systemPrompt: systemPrompt, tools: tools)
    }

    func stream(model: ProviderModel, systemPrompt: String?, messages: [Message], tools: [any AgentTool], options: StreamOptions) -> AsyncThrowingStream<AssistantEvent, Error> {
        streamingTask(model: model, messages: messages) { continuation in
            if definition.auth.adapter == "github-copilot" {
                let available = try await GitHubCopilotSubscriptionAccount.shared.availableModelIDs()
                guard available.contains(model.wireID) else { throw GitHubCopilotError(message: "This model is not available for your account") }
            }
            for try await event in native.stream(model: model, systemPrompt: systemPrompt, messages: messages, tools: tools, options: options) {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

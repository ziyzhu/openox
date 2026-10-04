import Foundation

nonisolated struct WebServiceModelProvider: ProviderClient {
    let id: String
    let domain: String
    let displayName: String
    let website: URL?
    let models: [ProviderModel]
    let regions: Set<LLMRegion>
    let usesAPIKey = false
    let canLoadModels = true
    let subscriptionAccount: (any SubscriptionAccount)? = nil

    static func providerID(domain: String) -> String {
        switch domain {
        case "qwen.ai": "qwen-web"
        case "www.kimi.com": "kimi-web"
        case "grok.com": "grok-web"
        case "claude.ai": "claude-web"
        default: "web:\(domain)"
        }
    }

    static func regions(domain: String) -> Set<LLMRegion> {
        switch domain {
        case "www.kimi.com": [.china]
        case "qwen.ai", "grok.com", "claude.ai": [.global]
        default: [.global, .china]
        }
    }

    static func model(id: String, name: String, input: Set<ProviderModelModality> = [.text], contextTokens: Int? = nil, outputTokens: Int? = nil) -> ProviderModel {
        ProviderModel(id: id == "website-default" ? id : "website:\(id)", providerModelID: id,
                      displayName: name, maxTokens: outputTokens ?? 4_096, maxContext: contextTokens ?? 32_768,
                      supportsTools: true, modalities: .init(input: input, output: [.text]))
    }

    func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { .web }

    @MainActor private func service() throws -> Service {
        guard let service = IOSHost.shared.services.service(domain: domain), service.definition.supportsModelGeneration else {
            throw WebsiteProviderError("The selected model service is unavailable. Resolve its service source or choose another model.")
        }
        return service
    }

    func websiteSessionIsAuthenticated() async throws -> Bool? {
        let state = try await service().checkAccess(policy: .current, reason: .modelSignIn)
        guard state != .unknown else { throw WebsiteProviderError("Model service sign-in could not be verified", kind: .authentication) }
        return state.isAuthenticated || state == .notRequired
    }

    private var signInRequiredError: WebsiteProviderError {
        WebsiteProviderError(String(localized: "Sign in with \(displayName) to use this model, or choose another model."), kind: .authentication)
    }

    private var signInVerificationError: WebsiteProviderError {
        WebsiteProviderError(String(localized: "Couldn't verify sign-in with \(displayName). Try again or choose another model."), kind: .authentication)
    }

    @MainActor private func requireAuthenticatedSession() async throws {
        let service = try service()
        try await service.awaitAuthenticationAvailability(name: "\(domain):modelGeneration")
        await service.checkAccess(policy: .current, reason: .modelSignIn)
        if service.auth.isSignedOut { await service.attemptSilentSignIn(reason: .modelSignIn) }
        try Task.checkCancellation()
        let state = service.signInState
        Log.service.info("ModelService.auth domain=\(domain) state=\(state.rawValue)")
        if state == .unknown { throw signInVerificationError }
        guard state.isAuthenticated || state == .notRequired else { throw signInRequiredError }
    }

    func loadModels() async throws -> [ProviderModel] {
        let value = try await service().invokeAction(ModelServiceContract.list, args: .object([:]), role: .modelGeneration).get()
        return try ModelServiceContract.models(from: value).map(\.model)
    }

    func stream(model: ProviderModel, systemPrompt: String?, messages: [Message], tools: [any AgentTool], options: StreamOptions) -> AsyncThrowingStream<AssistantEvent, Error> {
        streamingTask(model: model, messages: messages) { continuation in
            try await requireAuthenticatedSession()
            let instructions = [systemPrompt, WebsiteToolContract.instructions(tools)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let input = try WebsiteProviderPrompt.prepare(messages: messages, toolInstructions: instructions, providerName: displayName)
            let prepared = input.messages.arrayValue ?? []
            let chatID = options.sessionID.flatMap(UUID.init(uuidString:))
            let (context, turn) = try await WebModelContext.checkout(service: service(), chatID: chatID, modelID: model.wireID, options: options, messages: prepared)
            var generation: WebModelContext.Generation?
            do {
                let started = try await context.start(turn: turn, attachments: input.attachments)
                generation = started
                var assembler = StreamAssembler(model: model, continuation: continuation)
                assembler.start()
                var state = ModelServiceStreamState()
                var emittedText = ""
                let deadline = Date().addingTimeInterval(300)
                while !state.completed {
                    guard Date() < deadline else { throw WebsiteProviderError("Model generation timed out", kind: .network) }
                    let cursor = state.cursor
                    try state.accept(try await context.read(started, after: cursor))
                    if state.cursor == cursor { try await Task.sleep(for: .milliseconds(100)) }
                    if !WebsiteToolContract.isPossibleCallPrefix(state.text) {
                        assembler.textDelta(String(state.text.dropFirst(emittedText.count)))
                        emittedText = state.text
                    }
                }
                let reply: String
                if WebsiteToolContract.isPossibleCallPrefix(state.text) {
                    guard let call = try WebsiteToolContract.call(from: state.text, tools: tools) else {
                        throw WebsiteProviderError("Model service returned an incomplete Ox Action call")
                    }
                    reply = WebsiteToolContract.text(for: call)
                    assembler.completeToolCall(call)
                    assembler.finish(reason: .toolUse, label: id, lines: state.cursor)
                } else {
                    reply = state.text
                    assembler.finish(reason: .stop, label: id, lines: state.cursor)
                }
                await context.finish(started, history: prepared + [WebModelHistory.assistantTurn(reply)], chatID: chatID)
            } catch {
                await context.cancelAndClose(generation)
                if let invocationError = error as? Service.InvokeError {
                    switch invocationError {
                    case .requiresAuth: throw signInRequiredError
                    case .authUnavailable: throw signInVerificationError
                    default: break
                    }
                }
                throw error
            }
        }
    }
}

nonisolated extension ModelServiceContract {
    struct Model: Decodable, Sendable {
        let id: String
        let name: String
        let input: Set<ProviderModelModality>
        let contextTokens: Int?
        let outputTokens: Int?

        var model: ProviderModel {
            WebServiceModelProvider.model(id: id, name: name, input: input, contextTokens: contextTokens, outputTokens: outputTokens)
        }
    }

    static func models(from value: JSONValue) throws -> [Model] {
        struct Response: Decodable { let models: [Model] }
        let response = try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
        guard !response.models.isEmpty, response.models.count <= 100,
              response.models.contains(where: { $0.id == "website-default" }),
              Set(response.models.map(\.id)).count == response.models.count,
              response.models.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 100 && !$0.name.isEmpty && $0.name.count <= 100 && $0.input.contains(.text) && ($0.contextTokens ?? 1) > 0 && ($0.outputTokens ?? 1) > 0 }) else {
            throw WebsiteProviderError("Model service returned an invalid model list")
        }
        return response.models
    }
}

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

    static func model(id: String, name: String, input: Set<ProviderModelModality> = [.text], contextTokens: Int? = nil, outputTokens: Int? = nil) -> ProviderModel {
        ProviderModel(id: id == "website-default" ? id : "website:\(id)", providerModelID: id,
                      displayName: name, maxTokens: outputTokens ?? 4_096, maxContext: contextTokens ?? 32_768,
                      supportsTools: true, modalities: .init(input: input, output: [.text]))
    }

    func wireProtocol(for model: ProviderModel) -> LLMWireProtocol? { .web }

    func websiteSessionIsAuthenticated() async throws -> Bool? {
        try await ModelServiceSession.isSignedIn(domain: domain)
    }

    func loadModels() async throws -> [ProviderModel] {
        try await ModelServiceSession.loadModels(domain: domain).map(\.model)
    }

    func stream(model: ProviderModel, systemPrompt: String?, messages: [Message], tools: [any AgentTool], options: StreamOptions) -> AsyncThrowingStream<AssistantEvent, Error> {
        streamingTask(model: model, messages: messages) { continuation in
            let instructions = [systemPrompt, WebsiteToolContract.instructions(tools)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let input = try WebsiteProviderPrompt.prepare(messages: messages, toolInstructions: instructions, providerName: displayName)
            let session = try await ModelServiceSession.open(domain: domain)
            do {
                try await session.start(model: model, input: input, options: options, modalities: requiredInputModalities(in: messages))
                var assembler = StreamAssembler(model: model, continuation: continuation)
                assembler.start()
                var state = ModelServiceStreamState()
                var emittedText = ""
                while !state.completed {
                    try Task.checkCancellation()
                    try state.accept(await session.read(after: state.cursor))
                    if !WebsiteToolContract.isPossibleCallPrefix(state.text) {
                        assembler.textDelta(String(state.text.dropFirst(emittedText.count)))
                        emittedText = state.text
                    }
                    if !state.completed { try await Task.sleep(for: .milliseconds(100)) }
                }
                if WebsiteToolContract.isPossibleCallPrefix(state.text) {
                    guard let call = try WebsiteToolContract.call(from: state.text, tools: tools) else {
                        throw WebsiteProviderError("Model service returned an incomplete Ox Action call")
                    }
                    assembler.completeToolCall(call)
                    assembler.finish(reason: .toolUse, label: id, lines: state.cursor)
                } else {
                    assembler.finish(reason: .stop, label: id, lines: state.cursor)
                }
                await session.close()
            } catch {
                await session.cancelAndClose()
                throw error
            }
        }
    }
}

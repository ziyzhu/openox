import Foundation
import LiteRTLM

nonisolated struct LiteRTGemmaProvider: ProviderClient {
    static let contextTokens = 32_768

    let id = "on-device-gemma"
    let displayName = "On-device"
    let usesAPIKey = false
    let supportsTools = true
    let inferenceLocation: LLMInferenceLocation = .onDevice
    let models = [ProviderModel(
        id: OnDeviceModelStore.modelID,
        displayName: OnDeviceModelStore.modelName,
        maxTokens: 2_048,
        maxContext: Self.contextTokens,
        supportsTools: true
    )]

    func prepare(model: ProviderModel, systemPrompt: String?, tools: [any AgentTool]) async -> LLMPreparationOutcome {
        await OnDeviceModelStore.shared.state == .ready ? .ready : .unavailable
    }

    func stream(
        model: ProviderModel,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        options: StreamOptions
    ) -> AsyncThrowingStream<AssistantEvent, Error> {
        streamingTask(model: model, messages: messages) { continuation in
            let ready = await OnDeviceModelStore.shared.state == .ready
            guard ready else { throw RuntimeError.bridge("Install Gemma 4 E2B in Settings › Models before using it.") }
            let modelURL = await OnDeviceModelStore.shared.modelURL
            let response = try await LiteRTRuntime.shared.generate(
                modelURL: modelURL,
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools,
                maxOutputTokens: options.maxTokens ?? model.maxTokens,
                temperature: options.temperature
            )
            var assistant = AssistantMessage(model: model.id)
            continuation.yield(.start(partial: assistant))
            if let thought = response.channels["thought"], !thought.isEmpty {
                assistant.content.append(.thinking(ThinkingContent(thought)))
                continuation.yield(.thinkingDelta(index: assistant.content.count - 1, delta: thought, partial: assistant))
                continuation.yield(.thinkingEnd(index: assistant.content.count - 1, partial: assistant))
            }
            let text = response.toString
            if !text.isEmpty {
                assistant.content.append(.text(TextContent(text)))
                continuation.yield(.textDelta(index: assistant.content.count - 1, delta: text, partial: assistant))
                continuation.yield(.textEnd(index: assistant.content.count - 1, partial: assistant))
            }
            for call in response.toolCalls {
                let id = call.id.isEmpty ? UUID().uuidString : call.id
                let toolCall = ToolCall(id: id, name: call.name, arguments: JSONValue.from(call.arguments))
                assistant.content.append(.toolCall(toolCall))
                continuation.yield(.toolCallEnd(index: assistant.content.count - 1, toolCall: toolCall, partial: assistant))
            }
            assistant.stopReason = response.toolCalls.isEmpty ? .stop : .toolUse
            continuation.yield(.done(reason: assistant.stopReason, message: assistant))
            continuation.finish()
        }
    }
}

@MainActor
enum LiteRTModelActivation {
    private static var selectedChatID: UUID?
    private static var selectedClientID: String?
    private static var selectedModelID: String?
    private static var transition: Task<Void, Never>?

    static func select(chatID: UUID, clientID: String, modelID: String) {
        guard selectedChatID != chatID || selectedClientID != clientID || selectedModelID != modelID else { return }
        selectedChatID = chatID
        selectedClientID = clientID
        selectedModelID = modelID
        schedule(clientID == LiteRTGemmaProvider().id && modelID == OnDeviceModelStore.modelID
            ? OnDeviceModelStore.shared.modelURL : nil)
    }

    static func deselect(chatID: UUID) {
        guard selectedChatID == chatID else { return }
        selectedChatID = nil
        selectedClientID = nil
        selectedModelID = nil
        schedule(nil)
    }

    static func modelInstalled(at url: URL) {
        guard selectedClientID == LiteRTGemmaProvider().id,
              selectedModelID == OnDeviceModelStore.modelID else { return }
        schedule(url)
    }

    private static func schedule(_ url: URL?) {
        transition?.cancel()
        let previous = transition
        transition = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            guard let url, OnDeviceModelStore.shared.state == .ready else {
                await LiteRTRuntime.shared.unload()
                return
            }
            do {
                try await LiteRTRuntime.shared.preload(at: url)
            } catch is CancellationError {
            } catch {
                Log.agent.error("LiteRTGemma.preload failed error=\(error.localizedDescription)")
            }
        }
    }
}

actor LiteRTRuntime {
    static let shared = LiteRTRuntime()

    private var engine: Engine?
    private var loadedPath: String?
    private var loading: (path: String, task: Task<Void, Error>)?
    private var revision: UInt64 = 0

    func unload() {
        revision &+= 1
        if loadedPath != nil || loading != nil { Log.agent.info("LiteRTGemma.unload model=\(OnDeviceModelStore.modelID)") }
        loading?.task.cancel()
        loading = nil
        engine = nil
        loadedPath = nil
    }

    func preload(at url: URL) async throws {
        _ = try await loadedEngine(at: url)
    }

    func generate(
        modelURL: URL,
        systemPrompt: String?,
        messages: [Message],
        tools: [any AgentTool],
        maxOutputTokens: Int,
        temperature: Double?
    ) async throws -> LiteRTLM.Message {
        let engine = try await loadedEngine(at: modelURL)
        var history = try messages.compactMap(Self.convert)
        guard let last = history.popLast() else { throw RuntimeError.bridge("The local model received an empty conversation.") }
        let sampler = try temperature.map { try SamplerConfig(topK: 40, topP: 0.95, temperature: Float($0)) }
        let config = ConversationConfig(
            systemMessage: systemPrompt.map { LiteRTLM.Message($0, role: .system) },
            initialMessages: history,
            tools: tools.contains { $0.name == "execute" } ? [LiteRTExecuteTool()] : [],
            samplerConfig: sampler,
            automaticToolCalling: false
        )
        let conversation = try await engine.createConversation(with: config)
        Log.agent.info("LiteRTGemma.generate inputMessages=\(messages.count) tools=\(tools.count) maxOutput=\(maxOutputTokens)")
        let response = try await conversation.sendMessage(last, maxOutputTokens: maxOutputTokens)
        try Task.checkCancellation()
        Log.agent.info("LiteRTGemma.response textChars=\(response.toString.count) toolCalls=\(response.toolCalls.count)")
        return response
    }

    private func loadedEngine(at url: URL) async throws -> Engine {
        if let engine, loadedPath == url.path { return engine }
        if let loading, loading.path == url.path {
            try await loading.task.value
            guard let engine, loadedPath == url.path else { throw CancellationError() }
            return engine
        }
        loading?.task.cancel()
        revision &+= 1
        let expectedRevision = revision
        let cache = AppStoragePaths.caches.appendingPathComponent("LiteRTLM", isDirectory: true)
        let task = Task {
#if targetEnvironment(simulator)
            let (next, backend) = try await initializeEngine(at: url, cache: cache, backend: .cpu())
#else
            let (next, backend): (Engine, Backend)
            do {
                (next, backend) = try await initializeEngine(at: url, cache: cache, backend: .gpu)
            } catch {
                try Task.checkCancellation()
                Log.agent.error("LiteRTGemma.load fallback backend=gpu error=\(error.localizedDescription)")
                (next, backend) = try await initializeEngine(at: url, cache: cache, backend: .cpu())
            }
#endif
            try Task.checkCancellation()
            guard revision == expectedRevision else { throw CancellationError() }
            engine = next
            loadedPath = url.path
            Log.agent.info("LiteRTGemma.load done model=\(OnDeviceModelStore.modelID) backend=\(backend.rawValue)")
        }
        loading = (url.path, task)
        do {
            try await task.value
        } catch {
            if revision == expectedRevision { loading = nil }
            throw error
        }
        if revision == expectedRevision { loading = nil }
        guard let engine, loadedPath == url.path else { throw CancellationError() }
        return engine
    }

    private func initializeEngine(at url: URL, cache: URL, backend: Backend) async throws -> (Engine, Backend) {
        let backendCache = cache.appendingPathComponent(backend.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: backendCache, withIntermediateDirectories: true)
        let config = try EngineConfig(modelPath: url.path, backend: backend, maxNumTokens: LiteRTGemmaProvider.contextTokens, cacheDir: backendCache.path)
        let next = Engine(engineConfig: config)
        Log.agent.info("LiteRTGemma.load begin model=\(OnDeviceModelStore.modelID) backend=\(backend.rawValue)")
        try await next.initialize()
        return (next, backend)
    }

    private static func convert(_ message: Message) throws -> LiteRTLM.Message? {
        switch message {
        case .user(let user):
            let text = UserMessageParts(user, label: "LiteRTGemma.user").text
            return LiteRTLM.Message(text, role: .user)
        case .assistant(let assistant):
            let content = assistant.content.compactMap { block -> LiteRTLM.Content? in
                if case .text(let text) = block { return .text(text.text) }
                return nil
            }
            let calls = assistant.content.compactMap { block -> LiteRTLM.ToolCall? in
                guard case .toolCall(let call) = block else { return nil }
                return LiteRTLM.ToolCall(name: call.name, id: call.id, arguments: call.arguments.objectValue?.mapValues { $0.toAny() } ?? [:])
            }
            guard !content.isEmpty || !calls.isEmpty else {
                Log.agent.info("LiteRTGemma.history omitted assistant stopReason=\(assistant.stopReason) blocks=[\(assistant.content.blockKinds)]")
                return nil
            }
            return LiteRTLM.Message(contents: content, role: .model, toolCalls: calls)
        case .toolResult(let result):
            let text = result.content.compactMap { block -> String? in
                if case .text(let value) = block { return value.text }
                return nil
            }.joined(separator: "\n")
            return LiteRTLM.Message(contents: [.toolResponse(name: result.toolName, response: text, id: result.toolCallId)], role: .tool)
        }
    }
}

nonisolated private struct LiteRTExecuteTool: LiteRTLM.Tool {
    static let name = "execute"
    static let description = ChatJavaScriptTool.schema.description

    @ToolParam(description: "JavaScript snippet body. Use await and print results with console.log.")
    var source: String

    init() {}

    func run() async throws -> Any {
        throw RuntimeError.bridge("Ox executes tools through its agent runner.")
    }
}

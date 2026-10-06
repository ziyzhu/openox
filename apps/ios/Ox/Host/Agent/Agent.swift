import Foundation

nonisolated public struct AgentSnapshot: Sendable {
    public let systemPrompt: String
    public let model: ProviderModel
    public let tools: [any AgentTool]
    public let messages: [Message]
    public let streamingMessage: AssistantMessage?
    public let pendingToolCalls: Set<String>
    public let errorMessage: String?
    public let failureKind: LLMFailureKind?
    public let streamOptions: StreamOptions
    public let compactionThreshold: Double
    public let runState: Agent.RunState
}

public actor Agent {
    public enum RunState: Sendable, Equatable {
        case idle
        case running
    }

    public private(set) var configuration: AgentConfiguration
    public private(set) var messages: [Message] = []
    public private(set) var streamingMessage: AssistantMessage?
    public private(set) var pendingToolCalls: Set<String> = []
    public private(set) var errorMessage: String?
    public private(set) var failureKind: LLMFailureKind?
    public private(set) var runState = RunState.idle

    nonisolated public let events: AsyncStream<AgentEvent>
    nonisolated private let eventsContinuation: AsyncStream<AgentEvent>.Continuation

    private var durableDriver: DurableAgentDriver?

    func installDurableDriver(_ driver: DurableAgentDriver?) throws {
        guard activeRun == nil else { throw AgentRunError.busy }
        durableDriver = driver
    }

    nonisolated private enum DurableOperation: Sendable {
        case run(AgentRunRequest)
        case resume(submissionID: Int, requestID: String?)
    }

    private var lastTurnTokens = 0
    private var activeRun: (id: UUID, task: Task<AgentRunResult, Never>)?
    public var isStreaming: Bool { runState != .idle }

    public init(configuration: AgentConfiguration) {
        self.configuration = configuration
        let pair = AsyncStream.makeStream(of: AgentEvent.self)
        events = pair.stream
        eventsContinuation = pair.continuation
    }

    deinit {
        activeRun?.task.cancel()
        eventsContinuation.finish()
    }

    public func snapshot() -> AgentSnapshot {
        AgentSnapshot(
            systemPrompt: configuration.systemPrompt,
            model: configuration.model,
            tools: configuration.tools,
            messages: messages,
            streamingMessage: streamingMessage,
            pendingToolCalls: pendingToolCalls,
            errorMessage: errorMessage,
            failureKind: failureKind,
            streamOptions: configuration.streamOptions,
            compactionThreshold: configuration.compactionThreshold,
            runState: runState
        )
    }

    public func configure(_ configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    public func reset() {
        guard activeRun == nil else {
            Log.agent.error("Agent.reset ignored: run is active")
            return
        }
        messages = []
        runState = .idle
        streamingMessage = nil
        pendingToolCalls = []
        errorMessage = nil
        failureKind = nil
        lastTurnTokens = 0
    }

    public func restore(messages: [Message]) {
        guard !isStreaming, activeRun == nil else {
            Log.agent.error("Agent.restore ignored: loop is active")
            return
        }
        self.messages = messages
        Log.agent.info("Agent.restore seeded \(messages.count) messages")
    }

    public func abort() {
        activeRun?.task.cancel()
    }

    private func abort(runID: UUID) {
        guard activeRun?.id == runID else { return }
        abort()
    }

    func prepareDurableConfiguration() async throws {
        try Task.checkCancellation()
        guard activeRun == nil else { throw AgentRunError.busy }
        guard let driver = durableDriver else { throw RuntimeError.bridge("Pi conversation preparation has not completed") }
        _ = try await driver.prepare(configuration: configuration) { [weak self] event in
            await self?.emit(event)
        }
    }

    func resumeDurable(submissionID: Int, requestID: String? = nil) async throws -> AgentRunResult {
        try await start(.resume(submissionID: submissionID, requestID: requestID))
    }

    public func run(_ request: AgentRunRequest) async throws -> AgentRunResult {
        try await start(.run(request))
    }

    private func start(_ operation: DurableOperation) async throws -> AgentRunResult {
        try Task.checkCancellation()
        guard activeRun == nil else {
            Log.agent.error("Agent.run rejected: run is active")
            throw AgentRunError.busy
        }
        guard let driver = durableDriver else { throw RuntimeError.bridge("Pi conversation preparation has not completed") }
        runState = .running
        errorMessage = nil
        failureKind = nil
        streamingMessage = nil
        pendingToolCalls = []
        let runID = UUID()
        let initialConfiguration = configuration
        let task = Task { await execute(operation, configuration: initialConfiguration, driver: driver) }
        activeRun = (runID, task)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.abort(runID: runID) }
        }
    }

    public func waitForIdle() async {
        let task = activeRun?.task
        _ = await task?.value
    }

    private func execute(
        _ operation: DurableOperation,
        configuration: AgentConfiguration,
        driver: DurableAgentDriver
    ) async -> AgentRunResult {
        let result: AgentRunResult
        do {
            let sink: DurableAgentHost.EventSink = { [weak self] event in
                await self?.emit(event)
            }
            switch operation {
            case .run(let request):
                result = try await driver.run(request, configuration: configuration, seed: [], emit: sink)
            case .resume(let submissionID, let requestID):
                result = try await driver.resume(submissionID: submissionID, requestID: requestID, configuration: configuration, emit: sink)
            }
        } catch {
            result = AgentRunResult(outcome: Task.isCancelled ? .aborted : .failed(message: error.localizedDescription, kind: llmFailureKind(error: error)),
                                    messages: messages, lastTurnTokens: lastTurnTokens)
        }
        messages = result.messages
        errorMessage = result.errorMessage
        failureKind = result.failureKind
        lastTurnTokens = result.lastTurnTokens
        runState = .idle
        streamingMessage = nil
        pendingToolCalls = []
        activeRun = nil
        emit(.runFinished(result))
        return result
    }

    private func emit(_ event: AgentEvent) {
        reduce(event)
        eventsContinuation.yield(event)
    }

    private func reduce(_ event: AgentEvent) {
        switch event {
        case .messageStart(let message):
            if case .assistant(let assistant) = message { streamingMessage = assistant }
        case .messageEnd(let message):
            messages.append(message)
            if case .assistant = message { streamingMessage = nil }
        case .messageUpdate(let message, _):
            streamingMessage = message
        case .toolExecutionStart(let toolCall):
            pendingToolCalls.insert(toolCall.id)
        case .toolExecutionEnd(let toolCall, _):
            pendingToolCalls.remove(toolCall.id)
        case .generationFinished(let message, _):
            if let error = message.errorMessage {
                errorMessage = error
                failureKind = message.failureKind
            }
        case .runFinished:
            streamingMessage = nil
            pendingToolCalls = []
        case .runStarted(turnID: _),
             .generationStarted(model: _, turnID: _),
             .reasoning,
             .compacted:
            break
        }
    }
}

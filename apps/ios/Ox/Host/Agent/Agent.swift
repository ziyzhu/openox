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

    public func run(_ request: AgentRunRequest) async throws -> AgentRunResult {
        try Task.checkCancellation()
        guard activeRun == nil else {
            Log.agent.error("Agent.run rejected: run is active")
            throw AgentRunError.busy
        }
        runState = .running
        errorMessage = nil
        failureKind = nil
        streamingMessage = nil
        pendingToolCalls = []
        let runID = UUID()
        let initialConfiguration = configuration
        let task = Task { await execute(request, configuration: initialConfiguration) }
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
        _ request: AgentRunRequest,
        configuration: AgentConfiguration
    ) async -> AgentRunResult {
        let result: AgentRunResult
        if let durableDriver {
            do {
                result = try await durableDriver.run(request, configuration: configuration, seed: messages) { [weak self] event in
                    await self?.emit(event)
                }
            } catch {
                result = AgentRunResult(outcome: Task.isCancelled ? .aborted : .failed(message: error.localizedDescription, kind: llmFailureKind(error: error)),
                                        messages: messages, lastTurnTokens: lastTurnTokens)
            }
        } else {
            result = await runLegacy(request, configuration: configuration)
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

    // Compatibility boundary until persisted chats enter through the StorageMigrator gate.
    // No legacy snapshots, queues or compaction configuration are built on the Pi path.
    private func runLegacy(_ request: AgentRunRequest, configuration: AgentConfiguration) async -> AgentRunResult {
        let config = AgentRunConfig(
            turnID: request.turnID,
            snapshot: makeTurnSnapshot(messages: messages, configuration: configuration),
            transformContext: configuration.transformContext,
            beforeToolCall: configuration.beforeToolCall,
            afterToolCall: configuration.afterToolCall,
            shouldStopAfterTurn: configuration.shouldStopAfterTurn,
            toolExecutionMode: configuration.toolExecutionMode,
            priorTurnTokens: lastTurnTokens,
            refreshSnapshot: { [weak self] messages in await self?.makeTurnSnapshot(messages: messages) }
        )
        return await LogContext.$turnID.withValue(request.turnID) {
            await AgentRunner.run(newMessages: request.messages, config: config) { [weak self] event in
                await self?.emit(event)
            }
        }
    }

    private func makeTurnSnapshot(messages: [Message], configuration: AgentConfiguration? = nil) -> AgentTurnSnapshot {
        let configuration = configuration ?? self.configuration
        return AgentTurnSnapshot(
            context: AgentContext(systemPrompt: configuration.systemPrompt, messages: messages, tools: configuration.tools),
            client: configuration.client,
            model: configuration.model,
            streamOptions: configuration.streamOptions,
            compactionThreshold: configuration.compactionThreshold
        )
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

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
        case pausePending
        case paused
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

    private var lastTurnTokens = 0
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var activeRun: (id: UUID, task: Task<AgentRunResult, Never>)?
    private var steeringQueue = PendingMessageQueue()
    private var followUpQueue = PendingMessageQueue()

    public var isStreaming: Bool { runState != .idle }
    public var isPaused: Bool { runState == .paused }

    public var steeringMode: AgentQueueMode {
        get { steeringQueue.mode }
        set { steeringQueue.mode = newValue }
    }

    public var followUpMode: AgentQueueMode {
        get { followUpQueue.mode }
        set { followUpQueue.mode = newValue }
    }

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
        steeringQueue.clear()
        followUpQueue.clear()
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
        let continuation = resumeContinuation
        resumeContinuation = nil
        if runState == .pausePending || runState == .paused { runState = .running }
        steeringQueue.clear()
        followUpQueue.clear()
        activeRun?.task.cancel()
        continuation?.resume()
    }

    private func abort(runID: UUID) {
        guard activeRun?.id == runID else { return }
        abort()
    }

    public func pause() {
        guard runState == .running else { return }
        runState = .pausePending
        Log.agent.info("Agent.pause requested")
    }

    public func resume() {
        switch runState {
        case .paused:
            let continuation = resumeContinuation
            resumeContinuation = nil
            runState = .running
            Log.agent.info("Agent.resume")
            continuation?.resume()
        case .pausePending:
            runState = .running
            Log.agent.info("Agent.resume cleared pending pause request")
        case .idle, .running:
            break
        }
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
        let initialSnapshot = makeTurnSnapshot(messages: messages)
        let task = Task { await execute(request, configuration: initialConfiguration, snapshot: initialSnapshot) }
        activeRun = (runID, task)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.abort(runID: runID) }
        }
    }

    public func steer(_ text: String, attachments: [Artifact] = []) {
        steer([.user(UserMessage(text: text, attachments: attachments))])
    }

    public func steer(_ messages: [Message]) {
        steeringQueue.enqueue(messages)
    }

    public func followUp(_ text: String, attachments: [Artifact] = []) {
        followUp([.user(UserMessage(text: text, attachments: attachments))])
    }

    public func followUp(_ messages: [Message]) {
        followUpQueue.enqueue(messages)
    }

    public func clearSteeringQueue() {
        steeringQueue.clear()
    }

    public func clearFollowUpQueue() {
        followUpQueue.clear()
    }

    public func clearAllQueues() {
        steeringQueue.clear()
        followUpQueue.clear()
    }

    public func continueFromContext() async throws -> AgentRunResult {
        try Task.checkCancellation()
        guard activeRun == nil else { throw AgentRunError.busy }
        guard let last = messages.last else {
            throw AgentRunError.nothingToContinue
        }
        if case .assistant = last {
            let queued = steeringQueue.drain() + followUpQueue.drain()
            guard !queued.isEmpty else {
                throw AgentRunError.nothingToContinue
            }
            return try await run(AgentRunRequest(messages: queued))
        }
        return try await run(AgentRunRequest(messages: []))
    }

    public func waitForIdle() async {
        let task = activeRun?.task
        _ = await task?.value
    }

    private func execute(
        _ request: AgentRunRequest,
        configuration: AgentConfiguration,
        snapshot: AgentTurnSnapshot
    ) async -> AgentRunResult {
        let config = AgentRunConfig(
            turnID: request.turnID,
            snapshot: snapshot,
            shouldPause: { [weak self] in
                await self?.claimPause() ?? false
            },
            waitForResume: { [weak self] in
                await self?.waitUntilResumed()
            },
            getSteeringMessages: { [weak self] in
                await self?.drainSteeringMessages() ?? []
            },
            getFollowUpMessages: { [weak self] in
                await self?.drainFollowUpMessages() ?? []
            },
            transformContext: configuration.transformContext,
            beforeToolCall: configuration.beforeToolCall,
            afterToolCall: configuration.afterToolCall,
            shouldStopAfterTurn: configuration.shouldStopAfterTurn,
            toolExecutionMode: configuration.toolExecutionMode,
            priorTurnTokens: lastTurnTokens,
            refreshSnapshot: { [weak self] messages in
                await self?.makeTurnSnapshot(messages: messages)
            }
        )

        let result = await LogContext.$turnID.withValue(request.turnID) {
            await AgentRunner.run(newMessages: request.messages, config: config) { [weak self] event in
                await self?.emit(event)
            }
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

    private func claimPause() -> Bool {
        guard runState == .pausePending else { return false }
        runState = .paused
        return true
    }

    private func waitUntilResumed() async {
        guard runState == .paused else { return }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    private func drainSteeringMessages() -> [Message] {
        steeringQueue.drain()
    }

    private func drainFollowUpMessages() -> [Message] {
        followUpQueue.drain()
    }

    private func makeTurnSnapshot(messages: [Message]) -> AgentTurnSnapshot {
        AgentTurnSnapshot(
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
             .compacted,
             .paused,
             .resumed:
            break
        }
    }
}

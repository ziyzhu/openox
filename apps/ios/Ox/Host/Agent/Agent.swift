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

    public private(set) var systemPrompt = ""
    public private(set) var model: ProviderModel
    public private(set) var tools: [any AgentTool] = []
    public private(set) var messages: [Message] = []
    public private(set) var streamingMessage: AssistantMessage?
    public private(set) var pendingToolCalls: Set<String> = []
    public private(set) var errorMessage: String?
    public private(set) var failureKind: LLMFailureKind?
    public private(set) var runState = RunState.idle

    public var streamOptions = StreamOptions()
    public var compactionThreshold = 0.75
    public var transformContext: TransformContextHook?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var shouldStopAfterTurn: ShouldStopAfterTurnHook?
    public var toolExecutionMode = AgentToolExecutionMode.sequential

    nonisolated public let events: AsyncStream<AgentEvent>
    nonisolated private let eventsContinuation: AsyncStream<AgentEvent>.Continuation

    private var lastTurnTokens = 0
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var client: any ProviderClient
    private var currentTask: Task<Void, Never>?
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

    public init(
        client: any ProviderClient,
        model: ProviderModel,
        transformContext: TransformContextHook? = nil
    ) {
        self.client = client
        self.model = model
        self.transformContext = transformContext
        let pair = AsyncStream.makeStream(of: AgentEvent.self)
        events = pair.stream
        eventsContinuation = pair.continuation
    }

    deinit {
        currentTask?.cancel()
        eventsContinuation.finish()
    }

    public func snapshot() -> AgentSnapshot {
        AgentSnapshot(
            systemPrompt: systemPrompt,
            model: model,
            tools: tools,
            messages: messages,
            streamingMessage: streamingMessage,
            pendingToolCalls: pendingToolCalls,
            errorMessage: errorMessage,
            failureKind: failureKind,
            streamOptions: streamOptions,
            compactionThreshold: compactionThreshold,
            runState: runState
        )
    }

    public func configure(
        client: any ProviderClient,
        model: ProviderModel,
        systemPrompt: String,
        tools: [any AgentTool]
    ) {
        self.client = client
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
    }

    public func reset() {
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
        guard !isStreaming, currentTask == nil else {
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
        currentTask?.cancel()
        continuation?.resume()
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

    public func prompt(
        _ text: String,
        attachments: [Artifact] = [],
        transientContext: String? = nil,
        turnID: UUID? = nil
    ) {
        prompt(
            [.user(UserMessage(
                text: text,
                attachments: attachments,
                transientContext: transientContext
            ))],
            turnID: turnID
        )
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

    public func prompt(_ newMessages: [Message], turnID: UUID? = nil) {
        start(newMessages: newMessages, turnID: turnID)
    }

    public func continueFromContext() {
        guard currentTask == nil else { return }
        guard let last = messages.last else {
            Log.agent.error("Agent.continueFromContext ignored: no messages")
            return
        }
        if case .assistant = last {
            let queued = steeringQueue.drain() + followUpQueue.drain()
            guard !queued.isEmpty else {
                Log.agent.error("Agent.continueFromContext ignored: last message is assistant and no queued messages exist")
                return
            }
            start(newMessages: queued, turnID: nil)
            return
        }
        start(newMessages: [], turnID: nil)
    }

    public func waitForIdle() async {
        let task = currentTask
        await task?.value
    }

    private func start(newMessages: [Message], turnID: UUID?) {
        guard currentTask == nil else { return }
        runState = .running
        errorMessage = nil
        failureKind = nil
        streamingMessage = nil
        pendingToolCalls = []
        currentTask = Task { [weak self] in
            await self?.run(newMessages: newMessages, turnID: turnID)
        }
    }

    private func run(newMessages: [Message], turnID: UUID?) async {
        let initialSnapshot = makeTurnSnapshot(messages: messages)
        let config = AgentRunConfig(
            turnID: turnID,
            snapshot: initialSnapshot,
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
            transformContext: transformContext,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall,
            shouldStopAfterTurn: shouldStopAfterTurn,
            toolExecutionMode: toolExecutionMode,
            priorTurnTokens: lastTurnTokens,
            refreshSnapshot: { [weak self] messages in
                await self?.makeTurnSnapshot(messages: messages)
            }
        )

        let result = await LogContext.$turnID.withValue(turnID) {
            await AgentRunner.run(newMessages: newMessages, config: config) { [weak self] event in
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
        currentTask = nil
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
            context: AgentContext(systemPrompt: systemPrompt, messages: messages, tools: tools),
            client: client,
            model: model,
            streamOptions: streamOptions,
            compactionThreshold: compactionThreshold
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
        case .turnEnd(let message, _):
            if let error = message.errorMessage {
                errorMessage = error
                failureKind = message.failureKind
            }
        case .agentEnd:
            streamingMessage = nil
            pendingToolCalls = []
        case .agentStart(turnID: _),
             .turnStart(model: _, turnID: _),
             .reasoning,
             .compacted,
             .paused,
             .resumed:
            break
        }
    }
}

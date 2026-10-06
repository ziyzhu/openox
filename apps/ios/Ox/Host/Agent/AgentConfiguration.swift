import Foundation

nonisolated public struct AgentConfiguration: Sendable {
    public var client: any ProviderClient
    public var model: ProviderModel
    public var promptState: JSONValue
    public var tools: [any AgentTool]
    public var streamOptions: StreamOptions
    public var compactionThreshold: Double
    public var transformContext: TransformContextHook?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var shouldStopAfterTurn: ShouldStopAfterTurnHook?
    public var toolExecutionMode: AgentToolExecutionMode

    public init(
        client: any ProviderClient,
        model: ProviderModel,
        promptState: JSONValue,
        tools: [any AgentTool] = [],
        streamOptions: StreamOptions = StreamOptions(),
        compactionThreshold: Double = 0.75,
        transformContext: TransformContextHook? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        shouldStopAfterTurn: ShouldStopAfterTurnHook? = nil,
        toolExecutionMode: AgentToolExecutionMode = .sequential
    ) {
        self.client = client
        self.model = model
        self.promptState = promptState
        self.tools = tools
        self.streamOptions = streamOptions
        self.compactionThreshold = compactionThreshold
        self.transformContext = transformContext
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.shouldStopAfterTurn = shouldStopAfterTurn
        self.toolExecutionMode = toolExecutionMode
    }
}

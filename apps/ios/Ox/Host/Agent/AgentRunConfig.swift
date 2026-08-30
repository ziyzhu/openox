import Foundation

nonisolated struct AgentTurnSnapshot: Sendable {
    var context: AgentContext
    var client: any ProviderClient
    var model: ProviderModel
    var streamOptions: StreamOptions
    var compactionThreshold: Double
}

nonisolated struct AgentRunConfig: Sendable {
    var turnID: UUID?
    var snapshot: AgentTurnSnapshot
    var shouldPause: @Sendable () async -> Bool
    var waitForResume: @Sendable () async -> Void
    var getSteeringMessages: @Sendable () async -> [Message]
    var getFollowUpMessages: @Sendable () async -> [Message]
    var transformContext: TransformContextHook?
    var beforeToolCall: BeforeToolCallHook?
    var afterToolCall: AfterToolCallHook?
    var shouldStopAfterTurn: ShouldStopAfterTurnHook?
    var toolExecutionMode: AgentToolExecutionMode
    var priorTurnTokens: Int
    var refreshSnapshot: @Sendable ([Message]) async -> AgentTurnSnapshot?
}

nonisolated struct AgentRunResult: Sendable {
    var messages: [Message]
    var errorMessage: String?
    var failureKind: LLMFailureKind?
    var lastTurnTokens: Int
}

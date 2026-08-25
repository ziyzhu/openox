import Foundation

nonisolated public struct TransformContextRequest: Sendable {
    public let messages: [Message]
    public let model: ProviderModel

    public init(messages: [Message], model: ProviderModel) {
        self.messages = messages
        self.model = model
    }
}

public typealias TransformContextHook = @Sendable (TransformContextRequest) async -> [Message]

nonisolated public struct ShouldStopAfterTurnContext: Sendable {
    public var message: AssistantMessage
    public var toolResults: [ToolResultMessage]
    public var context: AgentContext

    public init(message: AssistantMessage, toolResults: [ToolResultMessage], context: AgentContext) {
        self.message = message
        self.toolResults = toolResults
        self.context = context
    }
}

public typealias ShouldStopAfterTurnHook = @Sendable (ShouldStopAfterTurnContext) async -> Bool

import Foundation

nonisolated public struct BeforeToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCall
    public var context: AgentContext

    public init(assistantMessage: AssistantMessage, toolCall: ToolCall, context: AgentContext) {
        self.assistantMessage = assistantMessage
        self.toolCall = toolCall
        self.context = context
    }
}

public struct BeforeToolCallResult: Sendable {
    public var block: Bool
    public var reason: String?

    public init(block: Bool = false, reason: String? = nil) {
        self.block = block
        self.reason = reason
    }
}

nonisolated public struct AfterToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCall
    public var context: AgentContext
    public var result: ToolResultMessage
    public var terminate: Bool

    public init(assistantMessage: AssistantMessage, toolCall: ToolCall, context: AgentContext, result: ToolResultMessage, terminate: Bool) {
        self.assistantMessage = assistantMessage
        self.toolCall = toolCall
        self.context = context
        self.result = result
        self.terminate = terminate
    }
}

public struct AfterToolCallResult: Sendable {
    public var content: [ContentBlock]?
    public var isError: Bool?
    public var terminate: Bool?

    public init(content: [ContentBlock]? = nil, isError: Bool? = nil, terminate: Bool? = nil) {
        self.content = content
        self.isError = isError
        self.terminate = terminate
    }
}

public typealias BeforeToolCallHook = @Sendable (BeforeToolCallContext) async -> BeforeToolCallResult?
public typealias AfterToolCallHook = @Sendable (AfterToolCallContext) async -> AfterToolCallResult?

import Foundation

nonisolated public enum AgentEvent: Sendable {
    case agentStart(turnID: UUID?)
    case agentEnd(messages: [Message])
    case turnStart(model: String, turnID: UUID?)
    case turnEnd(message: AssistantMessage, toolResults: [ToolResultMessage])
    case messageStart(Message)
    case messageUpdate(AssistantMessage, event: AssistantEvent)
    case messageEnd(Message)
    case toolExecutionStart(toolCall: ToolCall)
    case toolExecutionEnd(toolCall: ToolCall, result: ToolResultMessage)
    case reasoning(String)
    case compacted(beforeMessages: Int, afterMessages: Int, summaryChars: Int, tokensBefore: Int)
    case paused
    case resumed
}

import Foundation

nonisolated public enum AgentEvent: Sendable {
    case runStarted(turnID: UUID?)
    case runFinished(AgentRunResult)
    case generationStarted(model: String, turnID: UUID?)
    case generationFinished(message: AssistantMessage, toolResults: [ToolResultMessage])
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

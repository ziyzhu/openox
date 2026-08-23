import Foundation

nonisolated public enum AssistantEvent: Sendable {
    case start(partial: AssistantMessage)
    case textDelta(index: Int, delta: String, partial: AssistantMessage)
    case textEnd(index: Int, partial: AssistantMessage)
    case thinkingDelta(index: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(index: Int, partial: AssistantMessage)
    case toolCallDelta(index: Int, partial: AssistantMessage)
    case toolCallEnd(index: Int, toolCall: ToolCall, partial: AssistantMessage)
    case done(reason: StopReason, message: AssistantMessage)
    case failed(reason: StopReason, error: AssistantMessage)
}

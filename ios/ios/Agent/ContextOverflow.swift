import Foundation

nonisolated func isContextOverflow(_ message: AssistantMessage, contextWindow: Int) -> Bool {
    if message.stopReason == .error, message.failureKind == .contextOverflow { return true }
    guard contextWindow > 0 else { return false }
    let inputTokens = message.usage.input
    if message.stopReason == .stop, inputTokens > contextWindow { return true }
    return message.stopReason == .length
        && message.usage.output == 0
        && Double(inputTokens) >= Double(contextWindow) * 0.99
}

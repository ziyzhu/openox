import Foundation

nonisolated func isContextOverflow(_ message: AssistantMessage, contextWindow: Int, requestedOutput: Int) -> Bool {
    if message.stopReason == .error, message.failureKind == .contextOverflow { return true }
    guard contextWindow > 0 else { return false }
    let usage = message.usage
    if message.stopReason == .stop, usage.input > contextWindow { return true }
    guard message.stopReason == .length, usage.input > 0 else { return false }
    let exhaustedWindow = usage.output == 0 && Double(usage.input) >= Double(contextWindow) * 0.99
    let clampedByWindow = usage.output < requestedOutput && usage.input + requestedOutput > contextWindow
    return exhaustedWindow || clampedByWindow
}

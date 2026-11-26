import Foundation

nonisolated struct AssistantPartial: Sendable {
    var message: AssistantMessage?
    private var emittedReasoning: [Int: Int] = [:]

    mutating func reset() {
        message = nil
        emittedReasoning = [:]
    }

    mutating func reasoningEvents(_ assistant: AssistantMessage, completed: Bool) -> [AgentEvent] {
        assistant.content.enumerated().compactMap { index, block in
            guard case .thinking(let thinking) = block else { return nil }
            let utf8 = thinking.thinking.utf8
            let start = emittedReasoning[index] ?? 0
            let end = completed || index < assistant.content.count - 1 ? utf8.count
                : thinking.thinking.range(of: "\n\n", options: .backwards).map { utf8.distance(from: utf8.startIndex, to: $0.upperBound) } ?? 0
            guard end > start else { return nil }
            emittedReasoning[index] = end
            return .reasoning(String(decoding: utf8[utf8.index(utf8.startIndex, offsetBy: start)..<utf8.index(utf8.startIndex, offsetBy: end)], as: UTF8.self))
        }
    }

    mutating func applyDeltas(_ changes: [JSONValue]) -> [AssistantEvent] {
        guard var message else { return [] }
        var updates: [AssistantEvent] = []
        for change in changes {
            guard let fields = change.objectValue, let index = fields["contentIndex"]?.intValue,
                  let delta = fields["delta"]?.stringValue, message.content.indices.contains(index) else { continue }
            switch (fields["type"]?.stringValue, message.content[index]) {
            case ("text_delta", .text(var block)):
                block.text += delta
                message.content[index] = .text(block)
                updates.append(.textDelta(index: index, delta: delta, partial: message))
            case ("thinking_delta", .thinking(var block)):
                block.thinking += delta
                message.content[index] = .thinking(block)
                updates.append(.thinkingDelta(index: index, delta: delta, partial: message))
            default:
                continue
            }
        }
        self.message = message
        return updates
    }
}

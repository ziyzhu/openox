import Foundation

nonisolated public enum AgentQueueMode: Sendable {
    case oneAtATime
    case all
}

nonisolated struct PendingMessageQueue: Sendable {
    var mode: AgentQueueMode = .oneAtATime
    private var messages: [Message] = []

    var isEmpty: Bool { messages.isEmpty }

    mutating func enqueue(_ message: Message) {
        messages.append(message)
    }

    mutating func enqueue(_ newMessages: [Message]) {
        messages.append(contentsOf: newMessages)
    }

    mutating func drain() -> [Message] {
        switch mode {
        case .all:
            let drained = messages
            messages = []
            return drained
        case .oneAtATime:
            guard let first = messages.first else { return [] }
            messages.removeFirst()
            return [first]
        }
    }

    mutating func clear() {
        messages = []
    }
}

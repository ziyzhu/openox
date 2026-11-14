import Foundation

nonisolated public struct ConversationInput: Sendable {
    public let messages: [Message]
    public let turnID: UUID?
    public let turnState: JSONValue?

    public init(messages: [Message], turnID: UUID? = nil, turnState: JSONValue? = nil) {
        self.messages = messages
        self.turnID = turnID
        self.turnState = turnState
    }

    public init(
        text: String,
        attachments: [FileItem] = [],
        turnState: JSONValue? = nil,
        turnID: UUID? = nil
    ) {
        self.init(
            messages: [.user(UserMessage(text: text, attachments: attachments))],
            turnID: turnID,
            turnState: turnState
        )
    }
}

nonisolated public enum ConversationRunOutcome: Sendable, Equatable {
    case completed
    case aborted
    case failed(message: String, kind: LLMFailureKind?)
}

nonisolated public struct ConversationRunResult: Sendable {
    public let outcome: ConversationRunOutcome

    public var errorMessage: String? {
        switch outcome {
        case .completed: nil
        case .aborted: "aborted"
        case .failed(let message, _): message
        }
    }

    public var failureKind: LLMFailureKind? {
        if case .failed(_, let kind) = outcome { kind } else { nil }
    }
}

extension Conversation {
    static func userFacingError(_ raw: String, kind: LLMFailureKind?) -> String {
        if kind == .rateLimited {
            return "Rate limit reached — the model provider's quota is exhausted. Try again later or switch model."
        }
        if kind == .network {
            return "Network error — check your connection and try again."
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
    }

    static func outcome(for assistant: AssistantMessage, at: Date) -> TurnOutcome {
        if assistant.stopReason == .aborted { return .cancelled(at: at) }
        if let error = assistant.errorMessage { return .failed(at: at, message: error) }
        return .completed(at: at)
    }
}

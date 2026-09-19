import Foundation

nonisolated public struct AgentRunRequest: Sendable {
    public let messages: [Message]
    public let turnID: UUID?

    public init(messages: [Message], turnID: UUID? = nil) {
        self.messages = messages
        self.turnID = turnID
    }

    public init(
        text: String,
        attachments: [Artifact] = [],
        transientContext: String? = nil,
        turnID: UUID? = nil
    ) {
        self.init(
            messages: [.user(UserMessage(text: text, attachments: attachments, transientContext: transientContext))],
            turnID: turnID
        )
    }
}

nonisolated public enum AgentRunError: Error, LocalizedError, Sendable {
    case busy
    case nothingToContinue

    public var errorDescription: String? {
        switch self {
        case .busy: "Agent already has an active run."
        case .nothingToContinue: "Agent has no unfinished context or queued messages to continue."
        }
    }
}

nonisolated public enum AgentRunOutcome: Sendable, Equatable {
    case completed
    case aborted
    case failed(message: String, kind: LLMFailureKind?)
}

nonisolated public struct AgentRunResult: Sendable {
    public let outcome: AgentRunOutcome
    public let messages: [Message]
    public let lastTurnTokens: Int

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

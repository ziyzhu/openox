import Foundation

@MainActor
protocol HostConversationControlling {
    func sendText(_ text: String, to id: UUID, mode: HostConversationSendMode) async throws -> HostConversationSendResult
    func stopConversation(_ id: UUID) async throws -> HostConversationStopResult
    func respondToPrompt(_ promptID: UUID, in id: UUID, answer: String) async throws -> UUID
}

nonisolated enum HostConversationSendMode: Sendable {
    case enqueue
    case untilAttention
}

nonisolated struct HostConversationSendResult: Sendable {
    enum Outcome: Sendable {
        case queued
        case observed(ConversationSubmissionOutcome)
    }

    let conversationID: UUID
    let outcome: Outcome
}

nonisolated struct HostConversationStopResult: Sendable {
    let conversationID: UUID
    let wasRunning: Bool
}

nonisolated enum HostConversationControlError: LocalizedError {
    case missingText
    case stalePrompt
    case secureEntryRequired
    case invalidAnswer

    var errorDescription: String? {
        switch self {
        case .missingText: "missing text"
        case .stalePrompt: "pending prompt not found; inspect the conversation before responding"
        case .secureEntryRequired: "enter credentials in Ox, not through conversation responses"
        case .invalidAnswer: "provide one of the prompt options or an allowed custom answer"
        }
    }
}

@MainActor
struct EmbeddedHostConversationController: HostConversationControlling {
    private let host: any OxHost

    init(host: any OxHost) {
        self.host = host
    }

    func sendText(_ text: String, to id: UUID, mode: HostConversationSendMode) async throws -> HostConversationSendResult {
        guard !text.isEmpty else { throw HostConversationControlError.missingText }
        let conversation = try await load(id)
        Log.agent.info("HostConversation.send conversation=\(conversation.id) chars=\(text.count) mode=\(String(describing: mode))")
        switch mode {
        case .enqueue:
            conversation.enqueue(text)
            return HostConversationSendResult(conversationID: conversation.id, outcome: .queued)
        case .untilAttention:
            let outcome = await conversation.submitUntilAttention(text)
            Log.agent.info("HostConversation.send conversation=\(conversation.id) outcome=\(outcome.logLabel)")
            return HostConversationSendResult(conversationID: conversation.id, outcome: .observed(outcome))
        }
    }

    func stopConversation(_ id: UUID) async throws -> HostConversationStopResult {
        let conversation = try await load(id)
        let wasRunning = conversation.isBusy
        conversation.stopCurrentTurn()
        Log.agent.info("HostConversation.stop conversation=\(conversation.id) wasRunning=\(wasRunning)")
        return HostConversationStopResult(conversationID: conversation.id, wasRunning: wasRunning)
    }

    func respondToPrompt(_ promptID: UUID, in id: UUID, answer: String) async throws -> UUID {
        let conversation = try await load(id)
        guard case .prompt(let prompt) = conversation.interaction, prompt.id == promptID else {
            throw HostConversationControlError.stalePrompt
        }
        guard prompt.secretEntry == nil else { throw HostConversationControlError.secureEntryRequired }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              answer.count <= 2_000,
              prompt.allowsCustomAnswer || prompt.options.contains(answer) else {
            throw HostConversationControlError.invalidAnswer
        }
        conversation.resolvePrompt(blockId: prompt.id, answer: answer)
        Log.agent.info("HostConversation.respond conversation=\(conversation.id) prompt=\(prompt.id)")
        return conversation.id
    }

    private func load(_ id: UUID) async throws -> Conversation {
        try await host.prepare()
        try Task.checkCancellation()
        let conversation = try await host.conversations.loadForClient(id)
        try Task.checkCancellation()
        return conversation
    }
}

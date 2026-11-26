import Foundation

@MainActor
protocol ConversationControlling {
    func sendText(_ text: String, to id: UUID, mode: ConversationSendMode) async throws -> ConversationSendResult
    func stopConversation(_ id: UUID) async throws -> ConversationStopResult
    func respondToPrompt(_ promptID: UUID, in id: UUID, answer: String) async throws -> UUID
}

nonisolated enum ConversationSendMode: Sendable {
    case enqueue
    case untilAttention
}

nonisolated struct ConversationSendResult: Sendable {
    enum Outcome: Sendable {
        case queued
        case observed(ConversationSubmissionOutcome)
    }

    let conversationID: UUID
    let outcome: Outcome
}

nonisolated struct ConversationStopResult: Sendable {
    let conversationID: UUID
    let wasRunning: Bool
}

nonisolated enum ConversationControlError: LocalizedError {
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
struct EmbeddedConversationController: ConversationControlling {
    private let runtime: any ProfileRuntime

    init(runtime: any ProfileRuntime) {
        self.runtime = runtime
    }

    func sendText(_ text: String, to id: UUID, mode: ConversationSendMode) async throws -> ConversationSendResult {
        guard !text.isEmpty else { throw ConversationControlError.missingText }
        let conversation = try await load(id)
        Log.agent.info("ConversationControl.send conversation=\(conversation.id) chars=\(text.count) mode=\(String(describing: mode))")
        switch mode {
        case .enqueue:
            conversation.enqueue(text)
            return ConversationSendResult(conversationID: conversation.id, outcome: .queued)
        case .untilAttention:
            let outcome = await conversation.submitUntilAttention(text)
            Log.agent.info("ConversationControl.send conversation=\(conversation.id) outcome=\(outcome.logLabel)")
            return ConversationSendResult(conversationID: conversation.id, outcome: .observed(outcome))
        }
    }

    func stopConversation(_ id: UUID) async throws -> ConversationStopResult {
        let conversation = try await load(id)
        let wasRunning = conversation.isBusy
        conversation.stopCurrentTurn()
        Log.agent.info("ConversationControl.stop conversation=\(conversation.id) wasRunning=\(wasRunning)")
        return ConversationStopResult(conversationID: conversation.id, wasRunning: wasRunning)
    }

    func respondToPrompt(_ promptID: UUID, in id: UUID, answer: String) async throws -> UUID {
        let conversation = try await load(id)
        guard case .prompt(let prompt) = conversation.interaction, prompt.id == promptID else {
            throw ConversationControlError.stalePrompt
        }
        guard prompt.secretEntry == nil else { throw ConversationControlError.secureEntryRequired }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              answer.count <= 2_000,
              prompt.allowsCustomAnswer || prompt.options.contains(answer) else {
            throw ConversationControlError.invalidAnswer
        }
        conversation.resolvePrompt(blockId: prompt.id, answer: answer)
        Log.agent.info("ConversationControl.respond conversation=\(conversation.id) prompt=\(prompt.id)")
        return conversation.id
    }

    private func load(_ id: UUID) async throws -> Conversation {
        try await runtime.prepare()
        try Task.checkCancellation()
        let conversation = try await runtime.conversations.loadForClient(id)
        try Task.checkCancellation()
        return conversation
    }
}

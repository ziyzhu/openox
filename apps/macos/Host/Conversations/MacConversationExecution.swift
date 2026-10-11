import Foundation
import QuartzCore

@MainActor
struct MacConversationExecution: ConversationExecution {
    func backgroundExecution(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) -> any ConversationBackgroundExecution {
        MacConversationBackgroundExecution(conversationID: conversationID, runID: runID, onExpiration: onExpiration)
    }

    func protectPersistence(_ operation: @escaping @MainActor () async -> Void) {
        Task { await operation() }
    }

    func frameDriver(handler: @escaping @MainActor (CFTimeInterval) -> Void) -> any StreamFrameDriving {
        MacStreamFrameDriver(handler: handler)
    }
}

@MainActor
struct MacConversationFeedback: ConversationFeedback {
    var isBackground: Bool { false }

    func notifyAttention(identifier: String, title: String, body: String, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        false
    }

    func dismissAttention(identifier: String) {}

    func receivedAgentDelta() {}

    func notifyCompletion(id: UUID, title: String, body: String) {
        Log.session.info("Conversation.notify skipped id=\(id) reason=headless")
    }
}

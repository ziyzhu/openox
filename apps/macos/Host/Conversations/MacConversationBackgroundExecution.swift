import Foundation

@MainActor
final class MacConversationBackgroundExecution: ConversationBackgroundExecution {
    private let conversationID: UUID
    private let runID: RunID

    init(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) {
        self.conversationID = conversationID
        self.runID = runID
    }

    func submit() {
        Log.session.info("ConversationBackground.submit chat=\(conversationID) run=\(runID.rawValue) mode=process")
    }

    func advance() {
    }

    func updatePhase(_ phase: ConversationBackgroundPhase) {
        Log.session.info("ConversationBackground.phase chat=\(conversationID) run=\(runID.rawValue) phase=\(phase.rawValue) mode=process")
    }

    func updateStep(_ text: String) {
    }

    func finish(success: Bool) {
        Log.session.info("ConversationBackground.finish chat=\(conversationID) run=\(runID.rawValue) success=\(success) mode=process")
    }
}

import Foundation

@MainActor
final class ConversationBackgroundExecution {
    enum Phase: String {
        case thinking
        case working
        case responding
        case finishing
        case permissionNeeded
        case failed

        var subtitle: String {
            switch self {
            case .thinking: String(localized: "Plowing…")
            case .working: String(localized: "Plowing on a step…")
            case .responding: String(localized: "Writing a response…")
            case .finishing: String(localized: "Finishing up…")
            case .permissionNeeded: String(localized: "Permission needed")
            case .failed: String(localized: "Something went wrong")
            }
        }
    }

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

    func updatePhase(_ phase: Phase) {
        Log.session.info("ConversationBackground.phase chat=\(conversationID) run=\(runID.rawValue) phase=\(phase.rawValue) mode=process")
    }

    func updateStep(_ text: String) {
    }

    func finish(success: Bool) {
        Log.session.info("ConversationBackground.finish chat=\(conversationID) run=\(runID.rawValue) success=\(success) mode=process")
    }
}

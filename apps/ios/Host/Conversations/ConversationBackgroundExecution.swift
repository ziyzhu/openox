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
    private let execution: IOSConversationBackgroundExecution

    init(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) {
        self.conversationID = conversationID
        self.runID = runID
        execution = IOSConversationBackgroundExecution(conversationID: conversationID, runID: runID, onExpiration: onExpiration)
    }

    func submit() {
        execution.submit()
    }

    func advance() {
        execution.advance()
    }

    func updatePhase(_ phase: Phase) {
        execution.updatePhase(phase)
    }

    func updateStep(_ text: String) {
        execution.updateStep(text)
    }

    func finish(success: Bool) {
        execution.finish(success: success)
    }
}

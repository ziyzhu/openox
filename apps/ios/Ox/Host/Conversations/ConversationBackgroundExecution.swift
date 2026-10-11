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
    #if os(iOS)
    private let execution: IOSConversationBackgroundExecution
    #endif

    init(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) {
        self.conversationID = conversationID
        self.runID = runID
        #if os(iOS)
        execution = IOSConversationBackgroundExecution(conversationID: conversationID, runID: runID, onExpiration: onExpiration)
        #endif
    }

    func submit() {
        #if os(iOS)
        execution.submit()
        #else
        Log.session.info("ConversationBackground.submit chat=\(conversationID) run=\(runID.rawValue) mode=process")
        #endif
    }

    func advance() {
        #if os(iOS)
        execution.advance()
        #endif
    }

    func updatePhase(_ phase: Phase) {
        #if os(iOS)
        execution.updatePhase(phase)
        #else
        Log.session.info("ConversationBackground.phase chat=\(conversationID) run=\(runID.rawValue) phase=\(phase.rawValue) mode=process")
        #endif
    }

    func updateStep(_ text: String) {
        #if os(iOS)
        execution.updateStep(text)
        #endif
    }

    func finish(success: Bool) {
        #if os(iOS)
        execution.finish(success: success)
        #else
        Log.session.info("ConversationBackground.finish chat=\(conversationID) run=\(runID.rawValue) success=\(success) mode=process")
        #endif
    }
}

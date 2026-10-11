import Foundation
import QuartzCore

enum ConversationBackgroundPhase: String {
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

@MainActor
protocol ConversationBackgroundExecution: AnyObject {
    func submit()
    func advance()
    func updatePhase(_ phase: ConversationBackgroundPhase)
    func updateStep(_ text: String)
    func finish(success: Bool)
}

@MainActor
protocol ConversationExecution {
    func backgroundExecution(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) -> any ConversationBackgroundExecution
    func protectPersistence(_ operation: @escaping @MainActor () async -> Void)
    func frameDriver(handler: @escaping @MainActor (CFTimeInterval) -> Void) -> any StreamFrameDriving
}

@MainActor
protocol ConversationFeedback {
    func receivedAgentDelta()
    func notifyCompletion(id: UUID, title: String, body: String)
}

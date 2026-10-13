import Foundation
import QuartzCore

enum ConversationBackgroundPhase: String {
    case thinking
    case working
    case responding
    case finishing
    case inputNeeded
    case permissionNeeded
    case signInNeeded
    case verificationNeeded
    case paymentNeeded
    case stopped
    case expired
    case failed

    var title: String {
        switch self {
        case .thinking: String(localized: "Ox is thinking")
        case .working: String(localized: "Ox is working")
        case .responding: String(localized: "Ox is writing")
        case .finishing: String(localized: "Ox is wrapping up")
        case .inputNeeded: String(localized: "Ox needs your input")
        case .permissionNeeded: String(localized: "Ox needs your approval")
        case .signInNeeded: String(localized: "Sign in to continue")
        case .verificationNeeded: String(localized: "Verify to continue")
        case .paymentNeeded: String(localized: "Payment needed to continue")
        case .stopped: String(localized: "Ox stopped")
        case .expired: String(localized: "Open Ox to continue")
        case .failed: String(localized: "Ox hit a problem")
        }
    }

    var subtitle: String {
        switch self {
        case .thinking: String(localized: "Plowing…")
        case .working: String(localized: "Plowing on a step…")
        case .responding: String(localized: "Writing a response…")
        case .finishing: String(localized: "Finishing up…")
        case .inputNeeded: String(localized: "Input needed")
        case .permissionNeeded: String(localized: "Permission needed")
        case .signInNeeded: String(localized: "Sign-in needed")
        case .verificationNeeded: String(localized: "Verification needed")
        case .paymentNeeded: String(localized: "Payment needed")
        case .stopped: String(localized: "Stopped")
        case .expired: String(localized: "Background time ended")
        case .failed: String(localized: "Something went wrong")
        }
    }
}

enum ConversationBackgroundOutcome {
    case completed
    case failed
    case stopped
    case awaitingInput(ConversationBackgroundPhase)
    case expired

    var succeeded: Bool {
        switch self {
        case .completed, .awaitingInput: true
        case .failed, .stopped, .expired: false
        }
    }

    var phase: ConversationBackgroundPhase? {
        switch self {
        case .completed: nil
        case .failed: .failed
        case .stopped: .stopped
        case .awaitingInput(let phase): phase
        case .expired: .expired
        }
    }

    var logLabel: String {
        switch self {
        case .completed: "completed"
        case .failed: "failed"
        case .stopped: "stopped"
        case .awaitingInput: "awaitingInput"
        case .expired: "expired"
        }
    }
}

@MainActor
protocol ConversationBackgroundExecution: AnyObject {
    func submit()
    func advance()
    func updatePhase(_ phase: ConversationBackgroundPhase)
    func updateStep(_ text: String)
    func finish(_ outcome: ConversationBackgroundOutcome)
}

@MainActor
protocol ConversationExecution {
    func backgroundExecution(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) -> any ConversationBackgroundExecution
    func protectPersistence(_ operation: @escaping @MainActor () async -> Void)
    func frameDriver(handler: @escaping @MainActor (CFTimeInterval) -> Void) -> any StreamFrameDriving
}

@MainActor
protocol ConversationFeedback {
    var isBackground: Bool { get }
    func notifyAttention(identifier: String, title: String, body: String, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
    func dismissAttention(identifier: String)
    func receivedAgentDelta()
    func notifyCompletion(id: UUID, title: String, body: String)
}

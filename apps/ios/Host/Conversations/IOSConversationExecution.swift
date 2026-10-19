import Foundation
import UIKit
import QuartzCore

@MainActor
struct IOSConversationExecution: ConversationExecution {
    func backgroundExecution(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) -> any ConversationBackgroundExecution {
        IOSConversationBackgroundExecution(conversationID: conversationID, runID: runID, onExpiration: onExpiration)
    }

    func protectPersistence(_ operation: @escaping @MainActor () async -> Void) {
        let task = UIApplication.shared.beginBackgroundTask(withName: "ConversationManager.flushAll", expirationHandler: nil)
        Task {
            defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
            await operation()
        }
    }

    func frameDriver(handler: @escaping @MainActor (CFTimeInterval) -> Void) -> any StreamFrameDriving {
        IOSStreamFrameDriver(handler: handler)
    }
}

@MainActor
struct IOSConversationFeedback: ConversationFeedback {
    var isBackground: Bool { UIApplication.shared.applicationState == .background }

    func notifyAttention(identifier: String, title: String, body: String, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        try await NotificationProvider.shared.deliverIfAuthorized(identifier: identifier, title: title, body: body, isCurrent: isCurrent)
    }

    func dismissAttention(identifier: String) {
        NotificationProvider.shared.dismiss(identifier: identifier)
    }

    func receivedAgentDelta() {
        Haptics.impact(.agentDeltaReceived)
    }

    func notifyCompletion(id: UUID, title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else {
            Log.session.info("Conversation.notify skipped id=\(id) reason=active")
            return
        }
        let conversationId = id.uuidString
        Task {
            do {
                let delivered = try await NotificationProvider.shared.deliverIfAuthorized(
                    identifier: "conversation.\(conversationId)", title: title, body: body
                )
                if delivered {
                    Log.session.info("Conversation.notify posted id=\(conversationId) bodyChars=\(body.count)")
                } else {
                    Log.session.info("Conversation.notify skipped id=\(conversationId) reason=notAuthorized")
                }
            } catch {
                Log.session.error("Conversation.notify add failed id=\(conversationId) err=\(error.localizedDescription)")
            }
        }
    }
}

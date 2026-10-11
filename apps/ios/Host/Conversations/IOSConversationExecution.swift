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
    func receivedAgentDelta() {
        Haptics.impact(.agentDeltaReceived)
    }

    func notifyCompletion(id: UUID, title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else {
            Log.session.info("Conversation.notify skipped id=\(id) reason=active")
            return
        }
        let chatId = id.uuidString
        Task {
            do {
                let delivered = try await NotificationProvider.shared.deliverIfAuthorized(
                    identifier: "chat.\(chatId)", title: title, body: body
                )
                if delivered {
                    Log.session.info("Conversation.notify posted id=\(chatId) bodyChars=\(body.count)")
                } else {
                    Log.session.info("Conversation.notify skipped id=\(chatId) reason=notAuthorized")
                }
            } catch {
                Log.session.error("Conversation.notify add failed id=\(chatId) err=\(error.localizedDescription)")
            }
        }
    }
}

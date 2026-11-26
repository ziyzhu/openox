import Foundation
import UIKit
import QuartzCore

@MainActor
struct IOSConversationExecution: ConversationExecution {
    var foregroundExecutionAvailable: Bool { UIApplication.shared.applicationState == .active }

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
    static let didComplete = Notification.Name("Conversation.didComplete")

    var isBackground: Bool { UIApplication.shared.applicationState == .background }

    func notifyAttention(identifier: String, title: String, body: String, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        try await withBackgroundTime("Conversation.notifyAttention") {
            try await NotificationProvider.shared.deliverIfAuthorized(identifier: identifier, title: title, body: body, isCurrent: isCurrent)
        }
    }

    func dismissAttention(identifier: String) {
        NotificationProvider.shared.dismiss(identifier: identifier)
    }

    func startedConversation(firstSubmissionID: UUID) {
        ConversationReview.recordStart(firstSubmissionID: firstSubmissionID)
    }

    func notifyCompletion(id: UUID, title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else {
            NotificationCenter.default.post(
                name: Self.didComplete,
                object: id,
                userInfo: ["title": title, "body": body]
            )
            Log.session.info("Conversation.notify inApp id=\(id)")
            return
        }
        let conversationId = id.uuidString
        Task {
            await withBackgroundTime("Conversation.notifyCompletion") {
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

    private func withBackgroundTime<T>(_ name: String, _ operation: () async throws -> T) async rethrows -> T {
        let task = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: nil)
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        return try await operation()
    }
}

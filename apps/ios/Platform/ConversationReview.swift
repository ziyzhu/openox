import Foundation

@MainActor
enum ConversationReview {
    private static let conversationsKey = "review.startedConversations"
    private static let attemptsKey = "review.attemptedMilestones"
    private static let milestones = [3, 7, 14]

    static func recordStart(firstSubmissionID: UUID) {
        var conversations = UserDefaults.standard.stringArray(forKey: conversationsKey) ?? []
        let id = firstSubmissionID.uuidString
        guard conversations.count <= 14, !conversations.contains(id) else { return }
        conversations.append(id)
        UserDefaults.standard.set(conversations, forKey: conversationsKey)
        Log.ui.info("ConversationReview.started ordinal=\(conversations.count)")
    }

    static func eligibleMilestone(in conversation: Conversation) -> Int? {
        let conversations = UserDefaults.standard.stringArray(forKey: conversationsKey) ?? []
        let ordinal = conversations.count
        guard milestones.contains(ordinal),
              !(UserDefaults.standard.array(forKey: attemptsKey) as? [Int] ?? []).contains(ordinal),
              conversation.state.turns.count == 2,
              case let .user(first, _) = conversation.state.turns.first,
              let submissionID = first.submissionID,
              conversations.last == submissionID.rawValue.uuidString,
              case let .agent(turn, _) = conversation.state.turns.last,
              case .completed = turn.outcome else { return nil }
        return ordinal
    }

    static func recordAttempt(_ milestone: Int) -> Bool {
        var attempts = UserDefaults.standard.array(forKey: attemptsKey) as? [Int] ?? []
        guard milestones.contains(milestone), !attempts.contains(milestone) else { return false }
        attempts.append(milestone)
        UserDefaults.standard.set(attempts, forKey: attemptsKey)
        Log.ui.info("ConversationReview.requestAttempt milestone=\(milestone)")
        return true
    }
}

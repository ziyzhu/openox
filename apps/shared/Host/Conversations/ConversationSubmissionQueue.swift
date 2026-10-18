import Foundation
import Observation

@MainActor
@Observable
final class ConversationSubmissionQueue {
    struct Submission {
        enum Kind: Equatable {
            case user
            case system(resume: TurnID?)
        }

        enum State {
            case queued
            case posted
            case consumed
            case cancelled
        }

        let id: SubmissionID
        let kind: Kind
        let text: String
        let attachments: [FileItem]
        let skillInvocation: UserSkillInvocation?
        let latency: TurnLatencyTrace
        var state: State

        var needsPosting: Bool {
            guard case .user = kind else { return false }
            return state == .queued
        }

        var queuedMessage: Conversation.QueuedMessage? {
            guard needsPosting else { return nil }
            return Conversation.QueuedMessage(id: id.rawValue, text: text, attachments: attachments, skillInvocation: skillInvocation)
        }

        mutating func post() {
            guard needsPosting else { return }
            state = .posted
        }

        mutating func consume() {
            state = .consumed
        }
    }

    private(set) var submissions: [Submission] = []
    @ObservationIgnored private var waiters: [SubmissionID: CheckedContinuation<ConversationSubmissionOutcome, Never>] = [:]
    @ObservationIgnored private unowned let conversation: Conversation
    @ObservationIgnored private let responseText: (SubmissionID) -> String

    init(conversation: Conversation, responseText: @escaping (SubmissionID) -> String) {
        self.conversation = conversation
        self.responseText = responseText
    }

    var isEmpty: Bool { submissions.isEmpty }
    var count: Int { submissions.count }
    var next: Submission? { submissions.first }
    var queuedMessages: [Conversation.QueuedMessage] { submissions.compactMap(\.queuedMessage) }

    func queued(_ id: UUID) -> Submission? {
        submissions.first { $0.id.rawValue == id && $0.needsPosting }
    }

    func append(_ submission: Submission) {
        submissions.append(submission)
    }

    func take(_ id: SubmissionID) -> Submission? {
        guard let index = submissions.firstIndex(where: { $0.id == id }) else { return nil }
        return submissions.remove(at: index)
    }

    func remove(_ id: SubmissionID) {
        submissions.removeAll { $0.id == id }
    }

    func drain() -> [Submission] {
        let drained = submissions
        submissions.removeAll()
        return drained
    }

    func wait(for id: SubmissionID, _ continuation: CheckedContinuation<ConversationSubmissionOutcome, Never>) {
        waiters[id] = continuation
    }

    func detach(_ id: SubmissionID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: .cancelled)
        Log.session.info("Conversation.submitAndWait detached id=\(conversation.id) submission=\(id.rawValue) busy=\(conversation.isBusy)")
    }

    func cancelWaiters() {
        let cancelled = waiters.values
        waiters.removeAll()
        for continuation in cancelled { continuation.resume(returning: .cancelled) }
    }

    func resolve(
        _ submission: Submission,
        error: String?,
        failureKind: LLMFailureKind?,
        cancelled: Bool
    ) {
        guard let continuation = waiters.removeValue(forKey: submission.id) else { return }
        let outcome: ConversationSubmissionOutcome
        if cancelled {
            outcome = .cancelled
        } else if let error {
            outcome = .failed(Conversation.userFacingError(error, kind: failureKind))
        } else {
            let response = responseText(submission.id)
            outcome = response.isEmpty
                ? .failed("Ox finished without a text response.")
                : .completed(response)
        }
        continuation.resume(returning: outcome)
        Log.session.info("Conversation.submitAndWait resolved id=\(conversation.id) submission=\(submission.id.rawValue) outcome=\(outcome.logLabel)")
    }
}

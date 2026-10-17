@preconcurrency import BackgroundTasks
import Foundation

@MainActor
final class IOSConversationBackgroundExecution: ConversationBackgroundExecution {
    private static let activityPulseInterval = Duration.seconds(5)

    private final class CompletionState {
        var outcome: Outcome?
    }

    typealias Phase = ConversationBackgroundPhase

    typealias Outcome = ConversationBackgroundOutcome

    private let identifier: String
    private let conversationID: UUID
    private let runID: RunID
    private var task: BGContinuedProcessingTask?
    private var phase = Phase.thinking
    private var stepSubtitle: String?
    private var submittedAt: Date?
    private let completion = CompletionState()
    private var completedUnits: Int64 = 0
    private var lastProgressAt: Date?
    private var activityPulse: Task<Void, Never>?
    private var onExpiration: (() -> Void)?

    init(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.openox"
        identifier = "\(bundleID).conversation.\(runID.rawValue.uuidString).\(UUID().uuidString)"
        self.conversationID = conversationID
        self.runID = runID
        self.onExpiration = onExpiration
    }

    func submit() {
        guard completion.outcome == nil else { return }
        let completion = self.completion
        let identifier = self.identifier
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else {
                    let result = completion.outcome?.succeeded ?? false
                    task.setTaskCompleted(success: result)
                    Log.session.info("ConversationBackground.receive detached task=\(identifier) success=\(result)")
                    return
                }
                self.receive(task)
            }
        }
        guard registered else {
            completion.outcome = .failed
            onExpiration = nil
            Log.session.error("ConversationBackground.register rejected conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: phase.title,
            subtitle: subtitle
        )
        request.strategy = .queue
        do {
            submittedAt = Date()
            try BGTaskScheduler.shared.submit(request)
            Log.session.info("ConversationBackground.submit conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) strategy=queue")
        } catch {
            completion.outcome = .failed
            onExpiration = nil
            guard (error as? BGTaskScheduler.Error)?.code != .unavailable else {
                Log.session.info("ConversationBackground.submit unavailable conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier)")
                return
            }
            let failure = error as NSError
            Log.session.error("ConversationBackground.submit failed conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) domain=\(failure.domain) code=\(failure.code) error=\(failure.localizedDescription)")
        }
    }

    func advance() {
        guard completion.outcome == nil else { return }
        let now = Date()
        if let lastProgressAt, now.timeIntervalSince(lastProgressAt) < 1 { return }
        lastProgressAt = now
        completedUnits += 1
        task?.progress.totalUnitCount = completedUnits + 1
        task?.progress.completedUnitCount = completedUnits
    }

    func updatePhase(_ phase: Phase) {
        guard self.phase != phase || stepSubtitle != nil else { return }
        self.phase = phase
        stepSubtitle = nil
        Log.session.info("ConversationBackground.phase conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) phase=\(phase.rawValue) presented=\(task != nil)")
        guard completion.outcome == nil else { return }
        task?.updateTitle(phase.title, subtitle: subtitle)
    }

    func updateStep(_ text: String) {
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !value.isEmpty, completion.outcome == nil else { return }
        let subtitle = value.count > 120 ? String(value.prefix(119)) + "…" : value
        guard stepSubtitle != subtitle else { return }
        stepSubtitle = subtitle
        task?.updateTitle(phase.title, subtitle: subtitle)
    }

    func finish(_ outcome: Outcome) {
        guard completion.outcome == nil else { return }
        if let phase = outcome.phase { updatePhase(phase) }
        completion.outcome = outcome
        onExpiration = nil
        activityPulse?.cancel()
        activityPulse = nil
        if let task {
            if case .completed = outcome {
                task.updateTitle(String(localized: "Ox is done"), subtitle: String(localized: "Your response is ready"))
                let total = max(completedUnits + 1, 1)
                task.progress.totalUnitCount = total
                task.progress.completedUnitCount = total
            }
            task.setTaskCompleted(success: outcome.succeeded)
            self.task = nil
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        Log.session.info("ConversationBackground.finish conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) outcome=\(outcome.logLabel) success=\(outcome.succeeded)")
    }

    private func receive(_ rawTask: BGTask) {
        guard let task = rawTask as? BGContinuedProcessingTask else {
            rawTask.setTaskCompleted(success: false)
            return
        }
        if let outcome = completion.outcome {
            task.setTaskCompleted(success: outcome.succeeded)
            return
        }
        self.task = task
        activityPulse = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.activityPulseInterval)
                } catch {
                    return
                }
                guard let self else { return }
                self.advance()
            }
        }
        task.updateTitle(phase.title, subtitle: subtitle)
        task.progress.totalUnitCount = max(completedUnits + 1, 1)
        task.progress.completedUnitCount = completedUnits
        advance()
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expire()
            }
        }
        let latencyMs = submittedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? -1
        Log.session.info("ConversationBackground.start conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) latencyMs=\(latencyMs)")
    }

    private func expire() {
        guard completion.outcome == nil else { return }
        let interruptedPhase = phase
        let expiration = onExpiration
        finish(.expired)
        expiration?()
        let elapsedMs = submittedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? -1
        Log.session.warning("ConversationBackground.expire conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) phase=\(interruptedPhase.rawValue) elapsedMs=\(elapsedMs) completedUnits=\(completedUnits)")
    }

    private var subtitle: String { stepSubtitle ?? phase.subtitle }
}

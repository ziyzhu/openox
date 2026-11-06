@preconcurrency import BackgroundTasks
import Foundation

@MainActor
final class IOSConversationBackgroundExecution: ConversationBackgroundExecution {
    private static let activityPulseInterval = Duration.seconds(5)

    private enum State {
        case pending
        case submitted(at: Date)
        case running(BGContinuedProcessingTask, pulse: Task<Void, Never>, submittedAt: Date)
        case finished(ConversationBackgroundOutcome)
    }

    private let identifier: String
    private let conversationID: UUID
    private let runID: RunID
    private let onExpiration: () -> Void
    private var state = State.pending
    private var phase = ConversationBackgroundPhase.thinking
    private var stepSubtitle: String?
    private var completedUnits: Int64 = 0

    init(conversationID: UUID, runID: RunID, onExpiration: @escaping () -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.openox"
        identifier = "\(bundleID).conversation.\(runID.rawValue.uuidString).\(UUID().uuidString)"
        self.conversationID = conversationID
        self.runID = runID
        self.onExpiration = onExpiration
    }

    func submit() {
        guard case .pending = state else { return }
        let identifier = self.identifier
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else {
                    task.setTaskCompleted(success: true)
                    Log.session.info("ConversationBackground.receive detached task=\(identifier)")
                    return
                }
                self.receive(task)
            }
        }
        guard registered else {
            state = .finished(.failed)
            Log.session.error("ConversationBackground.register rejected conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: phase.title, subtitle: subtitle)
        request.strategy = .queue
        do {
            state = .submitted(at: Date())
            try BGTaskScheduler.shared.submit(request)
            Log.session.info("ConversationBackground.submit conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) strategy=queue")
        } catch {
            state = .finished(.failed)
            guard (error as? BGTaskScheduler.Error)?.code != .unavailable else {
                Log.session.info("ConversationBackground.submit unavailable conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier)")
                return
            }
            let failure = error as NSError
            Log.session.error("ConversationBackground.submit failed conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) domain=\(failure.domain) code=\(failure.code) error=\(failure.localizedDescription)")
        }
    }

    func updatePhase(_ phase: ConversationBackgroundPhase) {
        guard !isFinished, self.phase != phase || stepSubtitle != nil else { return }
        self.phase = phase
        stepSubtitle = nil
        Log.session.info("ConversationBackground.phase conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) phase=\(phase.rawValue) presented=\(runningTask != nil)")
        present()
    }

    func updateStep(_ text: String) {
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !value.isEmpty, !isFinished else { return }
        let subtitle = value.count > 120 ? String(value.prefix(119)) + "…" : value
        guard stepSubtitle != subtitle else { return }
        stepSubtitle = subtitle
        present()
    }

    func finish(_ outcome: ConversationBackgroundOutcome) {
        guard !isFinished else { return }
        if let phase = outcome.phase { updatePhase(phase) }
        if case .running(let task, let pulse, _) = state {
            pulse.cancel()
            if case .completed = outcome {
                task.updateTitle(String(localized: "Ox is done"), subtitle: String(localized: "Your response is ready"))
            }
            task.progress.totalUnitCount = completedUnits + 1
            task.progress.completedUnitCount = completedUnits + 1
            task.setTaskCompleted(success: true)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        state = .finished(outcome)
        Log.session.info("ConversationBackground.finish conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) outcome=\(outcome.logLabel) success=\(outcome.succeeded)")
    }

    private func receive(_ rawTask: BGTask) {
        guard let task = rawTask as? BGContinuedProcessingTask else {
            rawTask.setTaskCompleted(success: true)
            return
        }
        guard case .submitted(let submittedAt) = state else {
            task.setTaskCompleted(success: true)
            return
        }
        let pulse = Task { @MainActor [weak self] in
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
        state = .running(task, pulse: pulse, submittedAt: submittedAt)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expire()
            }
        }
        present()
        advance()
        let latencyMs = Int(Date().timeIntervalSince(submittedAt) * 1_000)
        Log.session.info("ConversationBackground.start conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) latencyMs=\(latencyMs)")
    }

    private func advance() {
        guard let task = runningTask else { return }
        completedUnits += 1
        task.progress.totalUnitCount = completedUnits + 1
        task.progress.completedUnitCount = completedUnits
    }

    private func expire() {
        guard case .running(_, _, let submittedAt) = state else { return }
        let elapsedMs = Int(Date().timeIntervalSince(submittedAt) * 1_000)
        Log.session.warning("ConversationBackground.expire conversation=\(conversationID) run=\(runID.rawValue) task=\(identifier) phase=\(phase.rawValue) elapsedMs=\(elapsedMs) completedUnits=\(completedUnits)")
        onExpiration()
        finish(.expired)
    }

    private func present() {
        runningTask?.updateTitle(phase.title, subtitle: subtitle)
    }

    private var runningTask: BGContinuedProcessingTask? {
        if case .running(let task, _, _) = state { task } else { nil }
    }

    private var isFinished: Bool {
        if case .finished = state { true } else { false }
    }

    private var subtitle: String { stepSubtitle ?? phase.subtitle }
}

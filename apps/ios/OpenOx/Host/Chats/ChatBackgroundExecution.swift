@preconcurrency import BackgroundTasks
import Foundation

@MainActor
final class ChatBackgroundExecution {
    private static var title: String { String(localized: "Ox is plowing") }

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

    private let identifier: String
    private let chatID: UUID
    private let runID: RunID
    private var task: BGContinuedProcessingTask?
    private var phase = Phase.thinking
    private var submittedAt: Date?
    private var terminalResult: Bool?
    private var completedUnits: Int64 = 0
    private var lastProgressAt: Date?
    private var onExpiration: (() -> Void)?

    init(chatID: UUID, runID: RunID, onExpiration: @escaping () -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.openox"
        identifier = "\(bundleID).chat.\(runID.rawValue.uuidString).\(UUID().uuidString)"
        self.chatID = chatID
        self.runID = runID
        self.onExpiration = onExpiration
    }

    func submit() {
        guard terminalResult == nil else { return }
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.receive(task)
            }
        }
        guard registered else {
            terminalResult = false
            onExpiration = nil
            Log.session.error("ChatBackground.register rejected chat=\(chatID) run=\(runID.rawValue) task=\(identifier)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: Self.title,
            subtitle: phase.subtitle
        )
        request.strategy = .queue
        do {
            submittedAt = Date()
            try BGTaskScheduler.shared.submit(request)
            Log.session.info("ChatBackground.submit chat=\(chatID) run=\(runID.rawValue) task=\(identifier) strategy=queue")
        } catch {
            terminalResult = false
            onExpiration = nil
            let failure = error as NSError
            Log.session.error("ChatBackground.submit failed chat=\(chatID) run=\(runID.rawValue) task=\(identifier) domain=\(failure.domain) code=\(failure.code) error=\(failure.localizedDescription)")
        }
    }

    func advance() {
        guard terminalResult == nil else { return }
        let now = Date()
        if let lastProgressAt, now.timeIntervalSince(lastProgressAt) < 1 { return }
        lastProgressAt = now
        completedUnits += 1
        task?.progress.totalUnitCount = completedUnits + 1
        task?.progress.completedUnitCount = completedUnits
    }

    func updatePhase(_ phase: Phase) {
        guard self.phase != phase else { return }
        self.phase = phase
        Log.session.info("ChatBackground.phase chat=\(chatID) run=\(runID.rawValue) task=\(identifier) phase=\(phase.rawValue) presented=\(task != nil)")
        guard terminalResult == nil else { return }
        task?.updateTitle(Self.title, subtitle: phase.subtitle)
    }

    func finish(success: Bool) {
        guard terminalResult == nil else { return }
        terminalResult = success
        onExpiration = nil
        if let task {
            let total = max(completedUnits + 1, 1)
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = total
            task.setTaskCompleted(success: success)
            self.task = nil
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        Log.session.info("ChatBackground.finish chat=\(chatID) run=\(runID.rawValue) task=\(identifier) success=\(success)")
    }

    private func receive(_ rawTask: BGTask) {
        guard let task = rawTask as? BGContinuedProcessingTask else {
            rawTask.setTaskCompleted(success: false)
            return
        }
        if let terminalResult {
            task.setTaskCompleted(success: terminalResult)
            return
        }
        self.task = task
        task.updateTitle(Self.title, subtitle: phase.subtitle)
        task.progress.totalUnitCount = max(completedUnits + 1, 1)
        task.progress.completedUnitCount = completedUnits
        advance()
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expire()
            }
        }
        let latencyMs = submittedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? -1
        Log.session.info("ChatBackground.start chat=\(chatID) run=\(runID.rawValue) task=\(identifier) latencyMs=\(latencyMs)")
    }

    private func expire() {
        guard terminalResult == nil else { return }
        terminalResult = true
        let expiration = onExpiration
        onExpiration = nil
        expiration?()
        task?.setTaskCompleted(success: true)
        task = nil
        Log.session.warning("ChatBackground.expire chat=\(chatID) run=\(runID.rawValue) task=\(identifier)")
    }
}

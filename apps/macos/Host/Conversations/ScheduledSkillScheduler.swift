import AppKit
import Foundation

@MainActor
final class ScheduledSkillScheduler {
    static let shared = ScheduledSkillScheduler()

    private weak var host: HostRuntime?
    private var timer: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var active = false

    private init() {}

    func configure(host: HostRuntime) {
        self.host = host
    }

    func activate() throws {
        try ScheduledSkills.shared.load()
        if !active {
            active = true
            ScheduledSkills.shared.onChange = { [weak self] in self?.refresh() }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    func refresh(minimumDelay: TimeInterval = 0) {
        timer?.cancel()
        timer = nil
        guard active, work == nil, let next = ScheduledSkills.shared.nextEnabledDate() else { return }
        let delay = max(minimumDelay, next.timeIntervalSinceNow)
        Log.app.info("MacSchedule.next delaySeconds=\(Int(delay))")
        timer = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                timer = nil
                work = Task {
                    let recorded = await processDue()
                    work = nil
                    refresh(minimumDelay: recorded ? 0 : 30)
                }
            } catch is CancellationError {
            } catch {
                Log.app.error("MacSchedule.timer failed error=\(error.localizedDescription)")
            }
        }
    }

    func runNow(id: UUID) {
        guard active else { return }
        do {
            try ScheduledSkills.shared.fireNow(id: id)
            refresh()
        } catch {
            Log.app.error("MacSchedule.runNow failed id=\(id) error=\(error.localizedDescription)")
        }
    }

    func stop() async {
        active = false
        timer?.cancel()
        timer = nil
        work?.cancel()
        await work?.value
        work = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func processDue() async -> Bool {
        guard let host else { return false }
        var recorded = true
        for schedule in ScheduledSkills.shared.due(at: Date()) {
            guard !Task.isCancelled else { return recorded }
            let outcome: ConversationSubmissionOutcome
            let conversationID: UUID?
            if StorageRoot.shared.activeId == schedule.profileID {
                (outcome, conversationID) = await host.conversations.runScheduledSkill(schedule, executionLease: .userInitiated)
            } else {
                outcome = .failed("Open the schedule's Profile to run it.")
                conversationID = nil
            }
            let result: ScheduledSkillRunOutcome = switch outcome {
            case .completed: .succeeded
            case .failed(let message): .failed(message)
            case .cancelled: .cancelled
            case .needsAttention: .failed("The scheduled skill needs attention in Ox.")
            }
            do {
                try ScheduledSkills.shared.record(id: schedule.id, outcome: result, conversationID: conversationID)
                Log.app.info("MacSchedule.record id=\(schedule.id) conversation=\(conversationID?.uuidString ?? "none")")
                if case .failed(let message) = result {
                    _ = try await NotificationProvider.shared.deliverIfAuthorized(
                        identifier: "scheduled-skill.\(schedule.id.uuidString)",
                        title: "Scheduled /\(schedule.skill.displayName) needs attention", body: message
                    )
                }
            } catch {
                recorded = false
                Log.app.error("MacSchedule.record failed id=\(schedule.id) error=\(error.localizedDescription)")
            }
        }
        return recorded
    }
}

@preconcurrency import BackgroundTasks
import Foundation

@MainActor
final class ScheduledSkillScheduler {
    static let shared = ScheduledSkillScheduler()

    private var identifier: String {
        "\(Bundle.main.bundleIdentifier ?? "ai.openox").scheduled-skills"
    }

    private var registered = false
    private var active = false
    private var work: Task<Void, Never>?

    private init() {}

    func register() {
        guard !registered else { return }
        registered = true
        let accepted = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                self?.receive(task)
            }
        }
        if accepted {
            Log.app.info("ScheduledSkillScheduler.register id=\(identifier)")
        } else {
            Log.app.error("ScheduledSkillScheduler.register rejected id=\(identifier)")
        }
    }

    func activate() throws {
        guard !active else {
            submitNext()
            return
        }
        register()
        try ScheduledSkills.shared.load()
        ScheduledSkills.shared.onChange = { [weak self] in
            self?.submitNext()
        }
        active = true
        refresh()
    }

    func refresh() {
        guard active else { return }
        guard work == nil, !ScheduledSkills.shared.due(at: Date()).isEmpty else {
            submitNext()
            return
        }
        startProcessing(executionLease: .userInitiated)
    }

    func runNow(id: UUID) {
        guard work == nil else {
            Log.app.info("ScheduledSkillScheduler.runNow queued id=\(id)")
            try? ScheduledSkills.shared.fireNow(id: id)
            return
        }
        do {
            try ScheduledSkills.shared.fireNow(id: id)
        } catch {
            Log.app.error("ScheduledSkillScheduler.runNow failed id=\(id) error=\(error.localizedDescription)")
            return
        }
        startProcessing(executionLease: .userInitiated)
    }

    private func startProcessing(executionLease: Chat.ExecutionLease) {
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processDue(executionLease: executionLease)
            self.work = nil
            self.submitNext()
        }
    }

    private func submitNext() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard let next = ScheduledSkills.shared.nextEnabledDate() else {
            Log.app.info("ScheduledSkillScheduler.submit disposition=empty")
            return
        }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = next
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.app.info("ScheduledSkillScheduler.submit next=\(ISODate.string(from: next))")
        } catch {
            let failure = error as NSError
            Log.app.error("ScheduledSkillScheduler.submit failed domain=\(failure.domain) code=\(failure.code) error=\(failure.localizedDescription)")
        }
    }

    private func receive(_ rawTask: BGTask) {
        guard let task = rawTask as? BGProcessingTask else {
            rawTask.setTaskCompleted(success: false)
            return
        }
        guard work == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        let worker = Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            do {
                try await IOSHost.shared.prepare()
                await self.processDue(executionLease: .externallyManaged)
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                Log.app.error("ScheduledSkillScheduler.run failed error=\(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
            self.work = nil
            self.submitNext()
        }
        work = worker
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.work?.cancel()
            }
        }
        Log.app.info("ScheduledSkillScheduler.start due=\(ScheduledSkills.shared.due(at: Date()).count)")
    }

    private func processDue(executionLease: Chat.ExecutionLease) async {
        for schedule in ScheduledSkills.shared.due(at: Date()) {
            guard !Task.isCancelled else { return }
            let outcome: ChatSubmissionOutcome
            let chatID: UUID?
            if StorageRoot.shared.activeId == schedule.profileID {
                (outcome, chatID) = await IOSHost.shared.chats.runScheduledSkill(
                    schedule,
                    executionLease: executionLease
                )
            } else {
                outcome = .failed("Open the schedule's Profile to run it.")
                chatID = nil
            }
            let runOutcome: ScheduledSkillRunOutcome = switch outcome {
            case .completed: .succeeded
            case .failed(let message): .failed(message)
            case .cancelled: .cancelled
            }
            do {
                try ScheduledSkills.shared.record(id: schedule.id, outcome: runOutcome, chatID: chatID)
            } catch {
                Log.app.error("ScheduledSkillScheduler.record failed id=\(schedule.id) error=\(error.localizedDescription)")
            }
            if case .failed(let message) = outcome {
                await notifyFailure(schedule: schedule, message: message)
            }
        }
    }

    private func notifyFailure(schedule: ScheduledSkill, message: String) async {
        do {
            _ = try await NotificationProvider.shared.deliverIfAuthorized(
                identifier: "scheduled-skill.\(schedule.id.uuidString)",
                title: "Scheduled /\(schedule.skill.displayName) needs attention",
                body: message
            )
        } catch {
            Log.app.error("ScheduledSkillScheduler.notify failed id=\(schedule.id) error=\(error.localizedDescription)")
        }
    }
}

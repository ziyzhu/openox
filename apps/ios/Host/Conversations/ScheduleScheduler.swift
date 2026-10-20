@preconcurrency import BackgroundTasks
import Foundation

@MainActor
final class ScheduleScheduler {
    static let shared = ScheduleScheduler()

    private var identifier: String {
        "\(Bundle.main.bundleIdentifier ?? "ai.openox").scheduled-skills"
    }

    private var registered = false
    private var active = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var runningID: UUID?

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
            Log.app.info("ScheduleScheduler.register id=\(identifier)")
        } else {
            Log.app.error("ScheduleScheduler.register rejected id=\(identifier)")
        }
    }

    func activate() async throws {
        guard !active else {
            submitNext()
            return
        }
        register()
        do { try await Schedules.shared.load() }
        catch {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            throw error
        }
        Schedules.shared.onChange = { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        active = true
        await refresh()
    }

    func stop() async {
        active = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        timer?.cancel()
        timer = nil
        work?.cancel()
        await work?.value
        work = nil
        Schedules.shared.unload()
        Log.app.info("ScheduleScheduler.stop")
    }

    func refresh() async {
        guard active else { return }
        do { try await Schedules.shared.expire() }
        catch { Log.app.error("Schedule.expire failed error=\(error.localizedDescription)") }
        guard active else { return }
        if let runningID {
            let state = Schedules.shared.schedule(id: runningID)?.state
            if state != .completed {
                if case .running = state {} else { work?.cancel() }
            }
        }
        timer?.cancel()
        timer = nil
        if work == nil, !Schedules.shared.due(at: Date()).isEmpty {
            startProcessing(executionLease: .userInitiated)
        } else {
            armTimer()
            submitNext()
        }
    }

    private func armTimer() {
        guard active else { return }
        let candidate = work == nil ? Schedules.shared.nextEnabledDate() : runningID.flatMap { Schedules.shared.schedule(id: $0)?.deadline }
        guard let next = candidate else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                await self?.refresh()
            } catch {}
        }
    }

    func runNow(id: UUID) async throws {
        guard active, Schedules.shared.isLoaded else { throw ScheduleError.invalidSchedule }
        try await Schedules.shared.fireNow(id: id)
        await refresh()
    }

    private func startProcessing(executionLease: Conversation.ExecutionLease) {
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processDue(executionLease: executionLease)
            self.work = nil
            await self.refresh()
        }
    }

    private func submitNext() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard active, let next = Schedules.shared.nextEnabledDate() else {
            Log.app.info("ScheduleScheduler.submit disposition=empty")
            return
        }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = next
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.app.info("ScheduleScheduler.submit next=\(ISODate.string(from: next))")
        } catch {
            let failure = error as NSError
            Log.app.error("ScheduleScheduler.submit failed domain=\(failure.domain) code=\(failure.code) error=\(failure.localizedDescription)")
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
                guard self.active, Schedules.shared.isLoaded else {
                    task.setTaskCompleted(success: false)
                    self.work = nil
                    await self.refresh()
                    return
                }
                await self.processDue(executionLease: .externallyManaged)
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                Log.app.error("ScheduleScheduler.run failed error=\(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
            self.work = nil
            await self.refresh()
        }
        work = worker
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.work?.cancel()
            }
        }
        Log.app.info("ScheduleScheduler.start due=\(Schedules.shared.due(at: Date()).count)")
    }

    private func processDue(executionLease: Conversation.ExecutionLease) async {
        for schedule in Schedules.shared.due(at: Date()) {
            guard !Task.isCancelled else { return }
            guard let current = Schedules.shared.schedule(id: schedule.id), current.state == .active else { continue }
            runningID = schedule.id
            let token: UUID
            do { token = try await Schedules.shared.claim(id: schedule.id) }
            catch {
                runningID = nil
                Log.app.error("Schedule.claim failed id=\(schedule.id) error=\(error.localizedDescription)")
                continue
            }
            let outcome: ConversationSubmissionOutcome
            let conversationID: UUID?
            if StorageRoot.shared.activeId == schedule.profileID {
                (outcome, conversationID) = await IOSHost.shared.conversations.runSchedule(
                    schedule,
                    token: token,
                    executionLease: executionLease
                )
            } else {
                outcome = .failed("Open the schedule's Profile to run it.")
                conversationID = nil
            }
            let runOutcome: ScheduleRunOutcome = switch outcome {
            case .completed: .succeeded
            case .failed(let message): .failed(message)
            case .cancelled: .cancelled
            case .needsAttention: .failed("The schedule needs attention in Ox.")
            }
            runningID = nil
            do {
                try await Schedules.shared.record(id: schedule.id, token: token, outcome: runOutcome, conversationID: conversationID)
            } catch {
                Log.app.error("ScheduleScheduler.record failed id=\(schedule.id) error=\(error.localizedDescription)")
            }
            if case .failed(let message) = runOutcome {
                await notifyFailure(schedule: schedule, message: message)
            }
        }
    }

    private func notifyFailure(schedule: Schedule, message: String) async {
        do {
            _ = try await NotificationProvider.shared.deliverIfAuthorized(
                identifier: "scheduled-skill.\(schedule.id.uuidString)",
                title: "\(schedule.name) needs attention",
                body: message
            )
        } catch {
            Log.app.error("ScheduleScheduler.notify failed id=\(schedule.id) error=\(error.localizedDescription)")
        }
    }
}

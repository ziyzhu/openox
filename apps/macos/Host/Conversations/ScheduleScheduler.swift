import AppKit
import Foundation

@MainActor
final class ScheduleScheduler {
    static let shared = ScheduleScheduler()

    private weak var host: HostRuntime?
    private var timer: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var active = false
    private var runningID: UUID?

    private init() {}

    func configure(host: HostRuntime) {
        self.host = host
    }

    func activate() async throws {
        try await Schedules.shared.load()
        if !active {
            active = true
            Schedules.shared.onChange = { [weak self] in Task { @MainActor in await self?.refresh() } }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        await refresh()
    }

    func refresh(minimumDelay: TimeInterval = 0) async {
        guard active else { return }
        do { try await Schedules.shared.expire() }
        catch { Log.app.error("MacSchedule.expire failed error=\(error.localizedDescription)") }
        guard active else { return }
        if let runningID {
            let state = Schedules.shared.schedule(id: runningID)?.state
            if state != .completed {
                if case .running = state {} else { work?.cancel() }
            }
        }
        timer?.cancel()
        timer = nil
        let candidate = work == nil ? Schedules.shared.nextEnabledDate() : runningID.flatMap { Schedules.shared.schedule(id: $0)?.deadline }
        guard let next = candidate else { return }
        let delay = max(1, minimumDelay, next.timeIntervalSinceNow)
        Log.app.info("MacSchedule.next delaySeconds=\(Int(delay))")
        timer = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                timer = nil
                if work != nil { await refresh(); return }
                work = Task {
                    let recorded = await processDue()
                    work = nil
                    await refresh(minimumDelay: recorded ? 0 : 30)
                }
            } catch is CancellationError {
            } catch {
                Log.app.error("MacSchedule.timer failed error=\(error.localizedDescription)")
            }
        }
    }

    func runNow(id: UUID) async throws {
        guard active else { throw ScheduleError.invalidSchedule }
        try await Schedules.shared.fireNow(id: id)
        await refresh()
    }

    func stop() async {
        active = false
        timer?.cancel()
        timer = nil
        work?.cancel()
        await work?.value
        work = nil
        Schedules.shared.unload()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func processDue() async -> Bool {
        guard let host else { return false }
        var recorded = true
        for schedule in Schedules.shared.due(at: Date()) {
            guard !Task.isCancelled else { return recorded }
            guard let current = Schedules.shared.schedule(id: schedule.id), current.state == .active else { continue }
            runningID = schedule.id
            let token: UUID
            do { token = try await Schedules.shared.claim(id: schedule.id) }
            catch {
                runningID = nil
                Log.app.error("MacSchedule.claim failed id=\(schedule.id) error=\(error.localizedDescription)")
                continue
            }
            let outcome: ConversationSubmissionOutcome
            let conversationID: UUID?
            if StorageRoot.shared.activeId == schedule.profileID {
                (outcome, conversationID) = await host.conversations.runSchedule(schedule, token: token, executionLease: .userInitiated)
            } else {
                outcome = .failed("Open the schedule's Profile to run it.")
                conversationID = nil
            }
            let result: ScheduleRunOutcome = switch outcome {
            case .completed: .succeeded
            case .failed(let message): .failed(message)
            case .cancelled: .cancelled
            case .needsAttention: .failed("The schedule needs attention in Ox.")
            }
            runningID = nil
            do {
                try await Schedules.shared.record(id: schedule.id, token: token, outcome: result, conversationID: conversationID)
                Log.app.info("MacSchedule.record id=\(schedule.id) conversation=\(conversationID?.uuidString ?? "none")")
                if case .failed(let message) = result {
                    _ = try await NotificationProvider.shared.deliverIfAuthorized(
                        identifier: "scheduled-skill.\(schedule.id.uuidString)",
                        title: "\(schedule.name) needs attention", body: message
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

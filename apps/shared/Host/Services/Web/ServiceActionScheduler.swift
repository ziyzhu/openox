import Foundation

@MainActor
final class ServiceActionScheduler {
    final class PresentationLease {
        let page: Service.ServiceWebPage
        let id: UUID
        private weak var scheduler: ServiceActionScheduler?

        fileprivate init(page: Service.ServiceWebPage, id: UUID, scheduler: ServiceActionScheduler) {
            self.page = page
            self.id = id
            self.scheduler = scheduler
        }

        var isActive: Bool { scheduler?.isReserved(page, for: id) == true }

        func release() {
            scheduler?.release(page, reservation: id)
        }
    }

    enum WorkKind {
        case invocation
        case navigation
        case presentation

        var isInvocation: Bool { self == .invocation }
    }

    private final class ScheduledAction {
        let id = UUID()
        let name: String
        let blocking: Bool
        let destination: URL?
        let submittedAt = Date()
        var kind: WorkKind
        var task: Task<Void, Never>?
        var perform: (@MainActor (Service.ServiceWebPage) async -> Void)?
        var fail: (@MainActor (any Error) -> Void)?

        init(name: String, blocking: Bool, destination: URL?, kind: WorkKind) {
            self.name = name
            self.blocking = blocking || kind != .invocation
            self.destination = destination
            self.kind = kind
        }

        func needsNavigation(on page: Service.ServiceWebPage) -> Bool {
            guard let destination else { return false }
            if case .unavailable = page.navigationPhase { return true }
            return destination != page.executionURL
        }

        func blocks(_ page: Service.ServiceWebPage) -> Bool {
            blocking || needsNavigation(on: page)
        }
    }

    private enum Occupancy {
        case idle
        case shared([UUID: ScheduledAction])
        case blocking(ScheduledAction)

        var actions: [ScheduledAction] {
            switch self {
            case .idle: []
            case .shared(let actions): Array(actions.values)
            case .blocking(let action): [action]
            }
        }

        var isIdle: Bool { if case .idle = self { true } else { false } }
        var allowsShared: Bool { if case .blocking = self { false } else { true } }

        mutating func start(_ action: ScheduledAction, blocking: Bool) {
            switch (self, blocking) {
            case (.idle, true): self = .blocking(action)
            case (.idle, false): self = .shared([action.id: action])
            case (.shared(var actions), false):
                actions[action.id] = action
                self = .shared(actions)
            case (.shared, true), (.blocking, _):
                preconditionFailure("invalid service action occupancy transition")
            }
        }

        mutating func finish(_ id: UUID) -> Bool {
            switch self {
            case .idle: return false
            case .blocking(let action):
                guard action.id == id else { return false }
                self = .idle
            case .shared(var actions):
                guard actions.removeValue(forKey: id) != nil else { return false }
                self = actions.isEmpty ? .idle : .shared(actions)
            }
            return true
        }
    }

    private final class PageQueue {
        enum State {
            case open
            case closing(@MainActor () -> Void)
        }

        let service: Service
        let page: Service.ServiceWebPage
        var pending: [ScheduledAction] = []
        var occupancy = Occupancy.idle
        var reservation: UUID?
        var state = State.open

        init(service: Service, page: Service.ServiceWebPage) {
            self.service = service
            self.page = page
        }

        var isOpen: Bool { if case .open = state { true } else { false } }
        var isIdle: Bool { pending.isEmpty && occupancy.isIdle && reservation == nil }
    }

    private var queues: [ObjectIdentifier: PageQueue] = [:]

    func schedule<Value>(
        _ action: Service.Action,
        on page: Service.ServiceWebPage,
        destination: URL? = nil,
        kind: WorkKind = .invocation,
        name: String? = nil,
        operation: @escaping @MainActor @Sendable (Service.ServiceWebPage) async throws -> Value
    ) async throws -> Value {
        let scheduled = ScheduledAction(
            name: name ?? "\(action.service.domain):\(action.definition.id)",
            blocking: action.blocking,
            destination: destination,
            kind: kind
        )
        guard action.service.owns(page) else { throw Service.EvalError.notReady }
        if case .unavailable = page.navigationPhase,
           kind == .invocation, !scheduled.needsNavigation(on: page) {
            throw Service.EvalError.notReady
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let key = ObjectIdentifier(page)
                let queue = queues[key] ?? PageQueue(service: action.service, page: page)
                guard queue.isOpen else {
                    continuation.resume(throwing: Service.EvalError.contextInvalidated)
                    return
                }
                queues[key] = queue
                var unresolved: CheckedContinuation<Value, any Error>? = continuation
                let settle: (Result<Value, any Error>) -> Void = { result in
                    guard let pending = unresolved else { return }
                    unresolved = nil
                    pending.resume(with: result)
                }
                scheduled.fail = { settle(.failure($0)) }
                scheduled.perform = { page in
                    do { settle(.success(try await operation(page))) }
                    catch { settle(.failure(error)) }
                }
                queue.pending.append(scheduled)
                Log.service.info("ServiceActionScheduler queued id=\(scheduled.id.uuidString.prefix(8)) name=\(scheduled.name) page=\(page.logLabel) phase=\(page.navigationPhase.logLabel) active=\(queue.occupancy.actions.count) pending=\(queue.pending.count)")
                pump(queue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(scheduled.id, on: page) }
        }
    }

    func reserveForPresentation(_ action: Service.Action, allowUnready: Bool = false) async throws -> PresentationLease? {
        guard let page = action.service.sessionPage(for: action) else { return nil }
        _ = await page.openingTask?.value
        guard page.isReady || allowUnready else { return nil }
        return try await schedule(action, on: page, kind: .presentation) { page in
            guard let queue = self.queues[ObjectIdentifier(page)], queue.isOpen else {
                throw Service.EvalError.contextInvalidated
            }
            let id = UUID()
            queue.reservation = id
            Log.service.info("ServiceActionScheduler presentation-reserved domain=\(queue.service.domain) page=\(page.logLabel)")
            return PresentationLease(page: page, id: id, scheduler: self)
        }
    }

    private func isReserved(_ page: Service.ServiceWebPage, for id: UUID) -> Bool {
        guard let queue = queues[ObjectIdentifier(page)] else { return false }
        return queue.isOpen && queue.reservation == id
    }

    private func release(_ page: Service.ServiceWebPage, reservation: UUID) {
        guard let queue = queues[ObjectIdentifier(page)], queue.reservation == reservation else { return }
        queue.reservation = nil
        Log.service.info("ServiceActionScheduler presentation-released domain=\(queue.service.domain) page=\(page.logLabel)")
        advance(page)
    }

    func isIdle(_ page: Service.ServiceWebPage) -> Bool {
        queues[ObjectIdentifier(page)]?.isIdle ?? true
    }

    func activeInvocationCount(on page: Service.ServiceWebPage) -> Int {
        queues[ObjectIdentifier(page)]?.occupancy.actions.count(where: { $0.kind.isInvocation }) ?? 0
    }

    func queuedInvocationCount(on page: Service.ServiceWebPage) -> Int {
        queues[ObjectIdentifier(page)]?.pending.count(where: { $0.kind.isInvocation }) ?? 0
    }

    func advance(_ page: Service.ServiceWebPage) {
        guard let queue = queues[ObjectIdentifier(page)] else { return }
        if case .closing(let close) = queue.state, queue.occupancy.isIdle, queue.reservation == nil {
            queues[ObjectIdentifier(page)] = nil
            close()
        } else {
            pump(queue)
        }
    }

    func failPending(on page: Service.ServiceWebPage, error: any Error) {
        guard let queue = queues[ObjectIdentifier(page)] else { return }
        let pending = queue.pending
        queue.pending.removeAll()
        pending.forEach { $0.fail?(error) }
        if !pending.isEmpty {
            Log.service.info("ServiceActionScheduler queue-failed domain=\(queue.service.domain) page=\(page.logLabel) count=\(pending.count) error=\(LogPrivacy.text(error.localizedDescription))")
        }
    }

    func closeWhenIdle(_ page: Service.ServiceWebPage, error: any Error, close: @escaping @MainActor () -> Void) {
        guard let queue = queues[ObjectIdentifier(page)] else { close(); return }
        guard queue.isOpen else { return }
        queue.state = .closing(close)
        failPending(on: page, error: error)
        advance(page)
    }

    func discard(_ page: Service.ServiceWebPage, error: any Error) {
        guard let queue = queues[ObjectIdentifier(page)] else { return }
        failPending(on: page, error: error)
        queues[ObjectIdentifier(page)] = nil
        for action in queue.occupancy.actions {
            action.fail?(error)
            action.task?.cancel()
        }
        queue.occupancy = .idle
        if case .closing(let close) = queue.state { close() }
    }

    private func pump(_ queue: PageQueue) {
        guard queue.isOpen, queue.reservation == nil, let first = queue.pending.first,
              queue.page.isReady || first.kind != .invocation || first.needsNavigation(on: queue.page) else { return }
        switch queue.page.navigationPhase {
        case .pending, .reserved, .navigating, .settling, .verifying:
            guard first.kind == .presentation else { return }
        case .ready, .unavailable:
            break
        }
        if first.blocks(queue.page) {
            guard queue.occupancy.isIdle else { return }
            start(queue.pending.removeFirst(), in: queue, blocking: true)
            return
        }
        while queue.occupancy.allowsShared,
              let next = queue.pending.first, !next.blocks(queue.page) {
            start(queue.pending.removeFirst(), in: queue, blocking: false)
        }
    }

    private func start(_ action: ScheduledAction, in queue: PageQueue, blocking: Bool) {
        queue.occupancy.start(action, blocking: blocking)
        let kind = action.kind
        if action.needsNavigation(on: queue.page) { action.kind = .navigation }
        let waitMS = Int(Date().timeIntervalSince(action.submittedAt) * 1_000)
        Log.service.info("ServiceActionScheduler admitted id=\(action.id.uuidString.prefix(8)) name=\(action.name) page=\(queue.page.logLabel) blocking=\(blocking) waitMs=\(waitMS) active=\(queue.occupancy.actions.count) pending=\(queue.pending.count)")
        action.task = Task { @MainActor [weak self, weak queue] in
            guard let self, let queue else { return }
            guard !Task.isCancelled else {
                action.fail?(CancellationError())
                self.finish(action, in: queue)
                return
            }
            if let destination = action.destination, action.needsNavigation(on: queue.page) {
                Log.service.info("ServiceActionScheduler navigation id=\(action.id.uuidString.prefix(8)) name=\(action.name) page=\(queue.page.logLabel) phase=\(queue.page.navigationPhase.logLabel) destinationChanged=\(destination != queue.page.executionURL)")
                guard await queue.service.navigate(destination, in: queue.page) != nil else {
                    action.fail?(queue.page.navigationFailure.map(Service.EvalError.navigationFailed) ?? .notReady)
                    self.finish(action, in: queue)
                    return
                }
                queue.page.executionURL = destination
            }
            action.kind = kind
            if Task.isCancelled { action.fail?(CancellationError()) }
            else { await action.perform?(queue.page) }
            self.finish(action, in: queue)
        }
    }

    private func finish(_ action: ScheduledAction, in queue: PageQueue) {
        guard queue.occupancy.finish(action.id) else { return }
        action.task = nil
        Log.service.info("ServiceActionScheduler released id=\(action.id.uuidString.prefix(8)) name=\(action.name) page=\(queue.page.logLabel) active=\(queue.occupancy.actions.count) pending=\(queue.pending.count)")
        if queue.isOpen { queue.service.advancePage(queue.page) }
        advance(queue.page)
    }

    private func cancel(_ id: UUID, on page: Service.ServiceWebPage) {
        guard let queue = queues[ObjectIdentifier(page)] else { return }
        if let index = queue.pending.firstIndex(where: { $0.id == id }) {
            queue.pending.remove(at: index).fail?(CancellationError())
            Log.service.info("ServiceActionScheduler cancelled id=\(id.uuidString.prefix(8)) page=\(page.logLabel) state=pending")
            queue.service.advancePage(page)
            advance(page)
        } else if let action = queue.occupancy.actions.first(where: { $0.id == id }) {
            action.fail?(CancellationError())
            action.task?.cancel()
            Log.service.info("ServiceActionScheduler cancelled id=\(id.uuidString.prefix(8)) page=\(page.logLabel) state=active")
        }
    }
}

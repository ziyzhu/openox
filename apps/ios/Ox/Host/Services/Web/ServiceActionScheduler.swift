import Foundation

@MainActor
final class ServiceActionScheduler {
    enum WorkKind {
        case invocation
        case navigation

        var isInvocation: Bool { self == .invocation }
    }

    private enum QueueKey: Hashable {
        case pooled(ObjectIdentifier, URL)
        case owned(ObjectIdentifier)
    }

    private final class Resolution<Value> {
        private var continuation: CheckedContinuation<Value, any Error>?

        init(_ continuation: CheckedContinuation<Value, any Error>) {
            self.continuation = continuation
        }

        func perform(
            on page: Service.ServiceWebPage,
            operation: @MainActor @Sendable (Service.ServiceWebPage) async throws -> Value
        ) async {
            guard continuation != nil else { return }
            do {
                settle(.success(try await operation(page)))
            } catch {
                settle(.failure(error))
            }
        }

        func fail(_ error: any Error) {
            settle(.failure(error))
        }

        private func settle(_ result: Result<Value, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private final class ScheduledAction {
        let id: UUID
        let name: String
        let role: Service.InvocationRole
        let kind: WorkKind
        let exclusive: Bool
        let submittedAt = Date()
        let perform: @MainActor (Service.ServiceWebPage) async -> Void
        let fail: @MainActor (any Error) -> Void
        var task: Task<Void, Never>?

        init<Value>(
            id: UUID,
            name: String,
            role: Service.InvocationRole,
            kind: WorkKind,
            continuation: CheckedContinuation<Value, any Error>,
            operation: @escaping @MainActor @Sendable (Service.ServiceWebPage) async throws -> Value
        ) {
            let resolution = Resolution(continuation)
            self.id = id
            self.name = name
            self.role = role
            self.kind = kind
            self.exclusive = role.requiresExclusiveAccess
            self.perform = { page in
                await resolution.perform(on: page, operation: operation)
            }
            self.fail = { error in
                resolution.fail(error)
            }
        }
    }

    private enum PageOccupancy {
        case idle
        case shared([UUID: ScheduledAction])
        case exclusive(ScheduledAction)

        var actions: [ScheduledAction] {
            switch self {
            case .idle: []
            case .shared(let actions): Array(actions.values)
            case .exclusive(let action): [action]
            }
        }

        var count: Int { actions.count }
        var isIdle: Bool { if case .idle = self { true } else { false } }
        var allowsShared: Bool { if case .exclusive = self { false } else { true } }

        func action(id: UUID) -> ScheduledAction? {
            switch self {
            case .idle: nil
            case .shared(let actions): actions[id]
            case .exclusive(let action): action.id == id ? action : nil
            }
        }

        mutating func start(_ action: ScheduledAction) {
            switch (self, action.exclusive) {
            case (.idle, true):
                self = .exclusive(action)
            case (.idle, false):
                self = .shared([action.id: action])
            case (.shared(var actions), false):
                actions[action.id] = action
                self = .shared(actions)
            case (.shared, true), (.exclusive, _):
                preconditionFailure("invalid service action occupancy transition")
            }
        }

        mutating func finish(_ id: UUID) -> Bool {
            switch self {
            case .idle:
                return false
            case .exclusive(let action):
                guard action.id == id else { return false }
                self = .idle
                return true
            case .shared(var actions):
                guard actions.removeValue(forKey: id) != nil else { return false }
                self = actions.isEmpty ? .idle : .shared(actions)
                return true
            }
        }
    }

    private final class ActionQueue {
        let key: QueueKey
        let service: Service
        let baseURL: URL
        let scripts: String
        let pooled: Bool
        var page: Service.ServiceWebPage?
        var pending: [ScheduledAction] = []
        var occupancy = PageOccupancy.idle
        var loadingTask: Task<Void, Never>?
        var invalidated = false
        var lastUsed: UInt64 = 0

        init(
            key: QueueKey,
            service: Service,
            baseURL: URL,
            scripts: String,
            pooled: Bool,
            page: Service.ServiceWebPage? = nil
        ) {
            self.key = key
            self.service = service
            self.baseURL = baseURL
            self.scripts = scripts
            self.pooled = pooled
            self.page = page
        }

        var isLoading: Bool { loadingTask != nil }
        var isIdle: Bool { pending.isEmpty && occupancy.isIdle && !isLoading }
    }

    private let capacity: Int
    private var queues: [QueueKey: ActionQueue] = [:]
    private var retiredQueues: [ActionQueue] = []
    private var waitingQueues: [QueueKey] = []
    private var accessOrdinal: UInt64 = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    func schedule<Value>(
        _ action: Service.Action,
        kind: WorkKind = .invocation,
        name: String? = nil,
        operation: @escaping @MainActor @Sendable (Service.ServiceWebPage) async throws -> Value
    ) async throws -> Value {
        let key = QueueKey.pooled(ObjectIdentifier(action.service), action.baseURL)
        return try await enqueue(
            action,
            key: key,
            page: nil,
            kind: kind,
            name: name,
            operation: operation
        )
    }

    func schedule<Value>(
        _ action: Service.Action,
        on page: Service.ServiceWebPage,
        kind: WorkKind = .invocation,
        name: String? = nil,
        operation: @escaping @MainActor @Sendable (Service.ServiceWebPage) async throws -> Value
    ) async throws -> Value {
        guard action.service.owns(page), page.isReady else { throw Service.EvalError.notReady }
        let key = QueueKey.owned(ObjectIdentifier(page))
        return try await enqueue(
            action,
            key: key,
            page: page,
            kind: kind,
            name: name,
            operation: operation
        )
    }

    func owns(_ page: Service.ServiceWebPage) -> Bool {
        pooledQueues.contains { $0.page === page }
    }

    func pages(for service: Service) -> [Service.ServiceWebPage] {
        pooledQueues.compactMap { $0.service === service ? $0.page : nil }
    }

    func activeInvocationCount(on page: Service.ServiceWebPage) -> Int {
        queue(for: page)?.occupancy.actions.count(where: { $0.kind.isInvocation }) ?? 0
    }

    func queuedInvocationCount(on page: Service.ServiceWebPage) -> Int {
        queue(for: page)?.pending.count(where: { $0.kind.isInvocation }) ?? 0
    }

    func advance(_ page: Service.ServiceWebPage) {
        guard let queue = queue(for: page), !queue.invalidated else { return }
        pump(queue)
        assignPages()
    }

    func failPending(on page: Service.ServiceWebPage, error: any Error) {
        guard let queue = queue(for: page) else { return }
        failPending(in: queue, error: error)
        if queue.pooled {
            retire(queue)
        }
    }

    func discard(_ page: Service.ServiceWebPage, error: any Error) {
        guard let queue = queue(for: page) else { return }
        discard(queue, error: error, closePage: false)
    }

    func invalidate(_ service: Service) {
        let matching = queues.values.filter { $0.pooled && $0.service === service }
        for queue in matching {
            failPending(in: queue, error: Service.EvalError.contextInvalidated)
            retire(queue)
        }
        assignPages()
    }

    func discardPages(for service: Service) {
        let matching = allQueues.filter { $0.pooled && $0.service === service }
        for queue in matching {
            discard(queue, error: CancellationError(), closePage: true)
        }
        assignPages()
    }

    func releaseIdle(reason: Service.PageReleaseReason) {
        let matching = pooledQueues.filter(\.isIdle)
        for queue in matching {
            discard(queue, error: CancellationError(), closePage: true)
        }
        if !matching.isEmpty {
            Log.webView.info("ServiceActionScheduler release reason=\(reason.rawValue) count=\(matching.count) resident=\(residentPageCount)")
        }
        assignPages()
    }

    private var allQueues: [ActionQueue] {
        Array(queues.values) + retiredQueues
    }

    private var pooledQueues: [ActionQueue] {
        allQueues.filter(\.pooled)
    }

    private var residentPageCount: Int {
        pooledQueues.count(where: { $0.page != nil })
    }

    private func enqueue<Value>(
        _ action: Service.Action,
        key: QueueKey,
        page: Service.ServiceWebPage?,
        kind: WorkKind,
        name: String?,
        operation: @escaping @MainActor @Sendable (Service.ServiceWebPage) async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let queue = queue(
                    for: key,
                    action: action,
                    page: page
                )
                let scheduled = ScheduledAction(
                    id: id,
                    name: name ?? "\(action.service.domain):\(action.definition.id)",
                    role: action.role,
                    kind: kind,
                    continuation: continuation,
                    operation: operation
                )
                queue.pending.append(scheduled)
                let wait = queue.page == nil ? "page" : "execution"
                Log.service.info("ServiceActionScheduler queued id=\(id.uuidString.prefix(8)) name=\(scheduled.name) queue=\(queueLabel(queue)) wait=\(wait) active=\(queue.occupancy.count) pending=\(queue.pending.count)")
                if queue.pooled, queue.page == nil, !waitingQueues.contains(key) {
                    waitingQueues.append(key)
                }
                assignPages()
                pump(queue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id)
            }
        }
    }

    private func queue(
        for key: QueueKey,
        action: Service.Action,
        page: Service.ServiceWebPage?
    ) -> ActionQueue {
        if let existing = queues[key] { return existing }
        let queue = ActionQueue(
            key: key,
            service: action.service,
            baseURL: action.baseURL,
            scripts: action.scripts,
            pooled: page == nil,
            page: page
        )
        queues[key] = queue
        touch(queue)
        return queue
    }

    private func queue(for page: Service.ServiceWebPage) -> ActionQueue? {
        allQueues.first { $0.page === page }
    }

    private func assignPages() {
        while let key = waitingQueues.first {
            guard let queue = queues[key], queue.pooled, queue.page == nil, !queue.pending.isEmpty else {
                waitingQueues.removeFirst()
                continue
            }
            if residentPageCount >= capacity {
                guard let victim = evictionVictim() else { return }
                discard(victim, error: CancellationError(), closePage: true)
            }
            waitingQueues.removeFirst()
            createPage(for: queue)
        }
    }

    private func createPage(for queue: ActionQueue) {
        let page = queue.service.makeServiceWebPage(actions: queue.scripts)
        queue.page = page
        touch(queue)
        let actionID = queue.pending.first?.name ?? "unknown"
        queue.loadingTask = Task { @MainActor [weak self, weak queue, weak page] in
            guard let self, let queue, let page else { return }
            let loaded = await queue.service.loadServiceWebPage(
                page,
                at: queue.baseURL,
                label: "scheduler:\(actionID)"
            )
            guard queue.page === page else { return }
            queue.loadingTask = nil
            guard loaded, !queue.invalidated else {
                self.failPending(in: queue, error: Service.EvalError.notReady)
                self.discard(queue, error: Service.EvalError.notReady, closePage: true)
                self.assignPages()
                return
            }
            Log.webView.info("ServiceActionScheduler page-ready queue=\(self.queueLabel(queue)) domain=\(queue.service.domain) session=\(page.logLabel) resident=\(self.residentPageCount)")
            self.pump(queue)
        }
    }

    private func pump(_ queue: ActionQueue) {
        guard !queue.invalidated,
              !queue.isLoading,
              let page = queue.page,
              page.isReady else { return }
        if queue.service.auth.isSigningIn {
            guard let index = queue.pending.firstIndex(where: { $0.role.isAuthenticationProbe }),
                  queue.occupancy.isIdle else { return }
            start(queue.pending.remove(at: index), in: queue, on: page)
            return
        }
        guard let first = queue.pending.first else { return }
        if first.exclusive {
            guard queue.occupancy.isIdle else { return }
            start(queue.pending.removeFirst(), in: queue, on: page)
            return
        }
        while queue.occupancy.allowsShared,
              queue.occupancy.count < Service.ServiceWebPage.maxConcurrentInvocations,
              queue.pending.first?.exclusive == false {
            start(queue.pending.removeFirst(), in: queue, on: page)
        }
    }

    private func start(_ action: ScheduledAction, in queue: ActionQueue, on page: Service.ServiceWebPage) {
        queue.occupancy.start(action)
        touch(queue)
        let waitMS = Int(Date().timeIntervalSince(action.submittedAt) * 1_000)
        let mode = action.exclusive ? "exclusive" : "shared"
        Log.service.info("ServiceActionScheduler admitted id=\(action.id.uuidString.prefix(8)) name=\(action.name) queue=\(queueLabel(queue)) session=\(page.logLabel) mode=\(mode) waitMs=\(waitMS) active=\(queue.occupancy.count) pending=\(queue.pending.count)")
        action.task = Task { @MainActor [weak self, weak queue, weak page] in
            guard let self, let queue, let page else { return }
            await action.perform(page)
            self.finish(action, in: queue, on: page)
        }
    }

    private func finish(_ action: ScheduledAction, in queue: ActionQueue, on page: Service.ServiceWebPage) {
        guard queue.occupancy.finish(action.id) else { return }
        action.task = nil
        touch(queue)
        Log.service.info("ServiceActionScheduler released id=\(action.id.uuidString.prefix(8)) name=\(action.name) queue=\(queueLabel(queue)) session=\(page.logLabel) active=\(queue.occupancy.count) pending=\(queue.pending.count)")
        if queue.invalidated, queue.occupancy.isIdle {
            discard(queue, error: Service.EvalError.contextInvalidated, closePage: true)
        } else {
            queue.service.advancePage(page)
        }
        assignPages()
    }

    private func cancel(_ id: UUID) {
        for queue in allQueues {
            if let index = queue.pending.firstIndex(where: { $0.id == id }) {
                let action = queue.pending.remove(at: index)
                action.fail(CancellationError())
                Log.service.info("ServiceActionScheduler cancelled id=\(id.uuidString.prefix(8)) name=\(action.name) queue=\(queueLabel(queue)) state=pending active=\(queue.occupancy.count) pending=\(queue.pending.count)")
                if queue.pooled, queue.page == nil, queue.pending.isEmpty {
                    waitingQueues.removeAll { $0 == queue.key }
                    queues[queue.key] = nil
                }
                if let page = queue.page { queue.service.advancePage(page) }
                assignPages()
                return
            }
            if let action = queue.occupancy.action(id: id) {
                action.fail(CancellationError())
                action.task?.cancel()
                Log.service.info("ServiceActionScheduler cancelled id=\(id.uuidString.prefix(8)) name=\(action.name) queue=\(queueLabel(queue)) state=active active=\(queue.occupancy.count) pending=\(queue.pending.count)")
                return
            }
        }
    }

    private func failPending(in queue: ActionQueue, error: any Error) {
        let pending = queue.pending
        queue.pending.removeAll()
        pending.forEach { $0.fail(error) }
        if !pending.isEmpty {
            Log.service.info("ServiceActionScheduler queue-failed queue=\(queueLabel(queue)) domain=\(queue.service.domain) count=\(pending.count) error=\(LogPrivacy.text(error.localizedDescription))")
        }
    }

    private func retire(_ queue: ActionQueue) {
        guard !queue.invalidated else { return }
        queue.invalidated = true
        waitingQueues.removeAll { $0 == queue.key }
        if queues[queue.key] === queue { queues[queue.key] = nil }
        queue.loadingTask?.cancel()
        queue.loadingTask = nil
        if queue.occupancy.isIdle {
            discard(queue, error: Service.EvalError.contextInvalidated, closePage: true)
        } else if !retiredQueues.contains(where: { $0 === queue }) {
            retiredQueues.append(queue)
        }
    }

    private func discard(_ queue: ActionQueue, error: any Error, closePage: Bool) {
        waitingQueues.removeAll { $0 == queue.key }
        if queues[queue.key] === queue { queues[queue.key] = nil }
        retiredQueues.removeAll { $0 === queue }
        queue.invalidated = true
        queue.loadingTask?.cancel()
        queue.loadingTask = nil
        failPending(in: queue, error: error)
        for action in queue.occupancy.actions {
            action.fail(error)
            action.task?.cancel()
        }
        queue.occupancy = .idle
        guard let page = queue.page else { return }
        queue.page = nil
        if closePage { queue.service.closeServiceWebPage(page, error: error) }
    }

    private func evictionVictim() -> ActionQueue? {
        pooledQueues
            .filter(\.isIdle)
            .min { $0.lastUsed < $1.lastUsed }
    }

    private func touch(_ queue: ActionQueue) {
        accessOrdinal &+= 1
        queue.lastUsed = accessOrdinal
    }

    private func queueLabel(_ queue: ActionQueue) -> String {
        switch queue.key {
        case .pooled:
            LogPrivacy.url(queue.baseURL.absoluteString)
        case .owned:
            "owned:\(queue.page?.logLabel ?? "released")"
        }
    }
}

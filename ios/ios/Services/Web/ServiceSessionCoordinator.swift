import Foundation

enum ServiceFlowKind: String {
    case authentication
    case botControl = "bot-control"
    case payment
}

enum ServiceFlowOutcome {
    case authentication
    case botControl(Bool)
    case payment(JSONValue)
    case cancelled
}

@MainActor
final class ServiceSessionCoordinator {
    private final class ActiveFlow {
        let id: UUID
        let kind: ServiceFlowKind
        let task: Task<ServiceFlowOutcome, Never>
        var session: ServiceFlowSession?

        init(id: UUID, kind: ServiceFlowKind, task: Task<ServiceFlowOutcome, Never>) {
            self.id = id
            self.kind = kind
            self.task = task
        }
    }

    private final class Waiter {
        let id: UUID
        let name: String
        var continuation: CheckedContinuation<Void, any Error>?

        init(id: UUID, name: String, continuation: CheckedContinuation<Void, any Error>) {
            self.id = id
            self.name = name
            self.continuation = continuation
        }

        func settle(_ result: Result<Void, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private var activeFlows: [ObjectIdentifier: ActiveFlow] = [:]
    private var waiters: [ObjectIdentifier: [Waiter]] = [:]

    func run(
        for service: Service,
        kind: ServiceFlowKind,
        operation: @escaping @MainActor (UUID) async -> ServiceFlowOutcome
    ) async -> ServiceFlowOutcome {
        let key = ObjectIdentifier(service)
        while let active = activeFlows[key] {
            if active.kind == kind {
                Log.service.info("ServiceSessionCoordinator join domain=\(service.domain) id=\(active.id.uuidString.prefix(8)) kind=\(kind.rawValue)")
                return await active.task.value
            }
            do {
                try await waitForChange(
                    for: service,
                    name: "flow:\(kind.rawValue):after:\(active.kind.rawValue)"
                )
            } catch {
                return .cancelled
            }
        }

        let id = UUID()
        let task = Task { @MainActor in await operation(id) }
        activeFlows[key] = ActiveFlow(id: id, kind: kind, task: task)
        Log.service.info("ServiceSessionCoordinator start domain=\(service.domain) id=\(id.uuidString.prefix(8)) kind=\(kind.rawValue)")
        let outcome = await task.value
        finish(for: service, id: id, kind: kind)
        return outcome
    }

    func cancel(for service: Service) {
        guard let active = activeFlows[ObjectIdentifier(service)] else { return }
        active.session?.close()
        active.task.cancel()
        Log.service.info("ServiceSessionCoordinator cancel domain=\(service.domain) id=\(active.id.uuidString.prefix(8)) kind=\(active.kind.rawValue)")
    }

    func attach(_ session: ServiceFlowSession) -> Bool {
        let key = ObjectIdentifier(session.service)
        guard let active = activeFlows[key],
              active.id == session.id,
              active.kind == session.kind else { return false }
        active.session = session
        return true
    }

    private func finish(for service: Service, id: UUID, kind: ServiceFlowKind) {
        let key = ObjectIdentifier(service)
        guard let active = activeFlows[key], active.id == id else { return }
        active.session?.close()
        activeFlows[key] = nil
        let pending = waiters.removeValue(forKey: key) ?? []
        pending.forEach { $0.settle(.success(())) }
        Log.service.info("ServiceSessionCoordinator finish domain=\(service.domain) id=\(id.uuidString.prefix(8)) kind=\(kind.rawValue) waiters=\(pending.count)")
    }

    private func waitForChange(for service: Service, name: String) async throws {
        let key = ObjectIdentifier(service)
        guard activeFlows[key] != nil else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard activeFlows[key] != nil else {
                    continuation.resume()
                    return
                }
                let waiter = Waiter(id: id, name: name, continuation: continuation)
                waiters[key, default: []].append(waiter)
                Log.service.info("ServiceSessionCoordinator wait domain=\(service.domain) id=\(id.uuidString.prefix(8)) name=\(name) waiters=\(waiters[key]?.count ?? 0)")
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(key: key, id: id, domain: service.domain)
            }
        }
    }

    private func cancelWaiter(key: ObjectIdentifier, id: UUID, domain: String) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[key]?.remove(at: index) else { return }
        if waiters[key]?.isEmpty == true { waiters[key] = nil }
        waiter.settle(.failure(CancellationError()))
        Log.service.info("ServiceSessionCoordinator wait-cancelled domain=\(domain) id=\(id.uuidString.prefix(8)) name=\(waiter.name)")
    }
}

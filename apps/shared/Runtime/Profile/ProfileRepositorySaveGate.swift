import Foundation
import Synchronization

nonisolated final class ProfileRepositorySaveGate: Sendable {
    private enum State {
        case open
        case held(entered: Bool, waiters: [CheckedContinuation<Void, Never>])
    }

    private let state = Mutex(State.open)

    var isEntered: Bool {
        state.withLock { if case .held(entered: true, _) = $0 { true } else { false } }
    }

    func hold() {
        state.withLock { if case .open = $0 { $0 = .held(entered: false, waiters: []) } }
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state = .open }
            guard case .held(_, let waiters) = state else { return [] }
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let held = state.withLock { state in
                guard case .held(_, let waiters) = state else { return false }
                state = .held(entered: true, waiters: waiters + [continuation])
                return true
            }
            if !held { continuation.resume() }
        }
    }
}

import Foundation
import Synchronization

nonisolated final class SubscriptionTokenStore<Tokens: Codable & Sendable>: @unchecked Sendable {
    struct Refresh: Sendable {
        let id: UUID
        let generation: UInt64
        let source: String
        let task: Task<Tokens, Error>
    }

    private struct State {
        var cached: Tokens?
        var loaded = false
        var generation: UInt64 = 0
        var refresh: Refresh?
    }

    private let key: String
    private let state = Mutex(State())

    init(key: String) {
        self.key = key
    }

    func current() -> Tokens? {
        state.withLock { state in
            if !state.loaded {
                if let raw = Credentials.secret(for: key),
                   let data = raw.data(using: .utf8),
                   let tokens = try? JSONDecoder().decode(Tokens.self, from: data) {
                    state.cached = tokens
                }
                state.loaded = true
            }
            return state.cached
        }
    }

    @discardableResult
    func persist(_ tokens: Tokens?, expectedGeneration: UInt64? = nil) -> Bool {
        let result = state.withLock { state -> (Bool, Task<Tokens, Error>?) in
            if let expectedGeneration, state.generation != expectedGeneration { return (false, nil) }
            let task = state.refresh?.task
            state.refresh = nil
            state.generation &+= 1
            state.cached = tokens
            state.loaded = true
            store(tokens)
            return (true, task)
        }
        result.1?.cancel()
        return result.0
    }

    func beginSignIn() -> UInt64 {
        let result = state.withLock { state -> (UInt64, Task<Tokens, Error>?) in
            let task = state.refresh?.task
            state.refresh = nil
            state.generation &+= 1
            return (state.generation, task)
        }
        result.1?.cancel()
        return result.0
    }

    func refreshTask(
        source: String,
        operation: @escaping @Sendable () async throws -> Tokens
    ) -> Refresh {
        state.withLock { state in
            if let refresh = state.refresh,
               refresh.generation == state.generation,
               refresh.source == source {
                return refresh
            }
            state.refresh?.task.cancel()
            let refresh = Refresh(
                id: UUID(),
                generation: state.generation,
                source: source,
                task: Task { try await operation() }
            )
            state.refresh = refresh
            return refresh
        }
    }

    func install(_ tokens: Tokens, from refresh: Refresh) -> Bool {
        state.withLock { state in
            guard state.refresh?.id == refresh.id else { return false }
            state.refresh = nil
            guard state.generation == refresh.generation else { return false }
            state.generation &+= 1
            state.cached = tokens
            state.loaded = true
            store(tokens)
            return true
        }
    }

    func clear(_ refresh: Refresh) {
        state.withLock { state in
            if state.refresh?.id == refresh.id { state.refresh = nil }
        }
    }

    private func store(_ tokens: Tokens?) {
        if let tokens,
           let data = try? JSONEncoder().encode(tokens),
           let raw = String(data: data, encoding: .utf8) {
            Credentials.setSecret(raw, for: key)
        } else {
            Credentials.clearSecret(for: key)
        }
    }
}

import Foundation

@MainActor
final class FileMutationCoordinator {
    static let shared = FileMutationCoordinator()

    private var active: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func perform<T>(key: String, operation: () async throws -> T) async throws -> T {
        await acquire(key)
        defer { release(key) }
        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    private func acquire(_ key: String) async {
        guard active.contains(key) else {
            active.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        guard var queued = waiters[key], !queued.isEmpty else {
            waiters[key] = nil
            active.remove(key)
            return
        }
        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.resume()
    }
}

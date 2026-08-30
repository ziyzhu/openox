import Foundation

nonisolated public enum OpenAIResponsesStreamingTransport: Sendable {
    case serverSentEvents
    case webSocketWithServerSentEventsFallback(accountHeader: String)
}

nonisolated struct OpenAIResponsesWebSocketFailure: Error {
    let underlying: Error
    let eventsReceived: Bool
}

nonisolated struct OpenAIResponsesWebSocketContinuation: Sendable {
    let requestBody: Data
    let responseID: String
    let responseOutput: Data
}

nonisolated struct OpenAIResponsesCompletion: Sendable {
    let responseID: String
    let responseOutput: Data
}

nonisolated struct OpenAIResponsesWebSocketEvents: AsyncSequence, @unchecked Sendable {
    typealias Element = [String: Any]

    struct AsyncIterator: AsyncIteratorProtocol {
        let task: URLSessionWebSocketTask

        mutating func next() async throws -> [String: Any]? {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let value): data = Data(value.utf8)
            case .data(let value): data = value
            @unknown default: throw OpenAIClientError(message: "Unsupported ChatGPT WebSocket message")
            }
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OpenAIClientError(message: "Invalid ChatGPT WebSocket event")
            }
            return event
        }
    }

    let task: URLSessionWebSocketTask

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(task: task)
    }
}

actor OpenAIResponsesWebSocketPool {
    static let shared = OpenAIResponsesWebSocketPool()

    struct Lease: @unchecked Sendable {
        let task: URLSessionWebSocketTask
        let key: Key?
        let continuation: OpenAIResponsesWebSocketContinuation?
        let reused: Bool
    }

    struct Key: Hashable, Sendable {
        let sessionID: String
        let accountID: String
    }

    private struct Entry {
        let task: URLSessionWebSocketTask
        let createdAt: ContinuousClock.Instant
        var busy: Bool
        var continuation: OpenAIResponsesWebSocketContinuation?
        var expiration: Task<Void, Never>?
    }

    private let clock = ContinuousClock()
    private let idleDuration: Duration = .seconds(5 * 60)
    private let maximumAge: Duration = .seconds(55 * 60)
    private var entries: [Key: Entry] = [:]
    private var fallbackSessions = Set<String>()

    func fallbackActive(sessionID: String?) -> Bool {
        sessionID.map(fallbackSessions.contains) ?? false
    }

    func acquire(request: URLRequest, sessionID: String?, accountID: String) -> Lease {
        guard let sessionID else {
            let task = makeTask(request)
            return Lease(task: task, key: nil, continuation: nil, reused: false)
        }

        let key = Key(sessionID: sessionID, accountID: accountID)
        if var entry = entries[key] {
            entry.expiration?.cancel()
            entry.expiration = nil
            if !entry.busy,
               entry.createdAt.duration(to: clock.now) < maximumAge,
               entry.task.state == .running {
                entry.busy = true
                entries[key] = entry
                return Lease(task: entry.task, key: key, continuation: entry.continuation, reused: true)
            }
            if !entry.busy {
                entry.task.cancel(with: .normalClosure, reason: Data("connection_age_limit".utf8))
                entries.removeValue(forKey: key)
            } else {
                let task = makeTask(request)
                return Lease(task: task, key: nil, continuation: nil, reused: false)
            }
        }

        let task = makeTask(request)
        entries[key] = Entry(task: task, createdAt: clock.now, busy: true)
        return Lease(task: task, key: key, continuation: nil, reused: false)
    }

    func release(
        _ lease: Lease,
        keep: Bool,
        continuation: OpenAIResponsesWebSocketContinuation?
    ) {
        guard let key = lease.key else {
            lease.task.cancel(with: .normalClosure, reason: Data("done".utf8))
            return
        }
        guard var entry = entries[key], entry.task === lease.task else {
            lease.task.cancel(with: .normalClosure, reason: Data("done".utf8))
            return
        }
        guard keep, entry.task.state == .running else {
            entry.expiration?.cancel()
            entry.task.cancel(with: .normalClosure, reason: Data("done".utf8))
            entries.removeValue(forKey: key)
            return
        }
        entry.busy = false
        entry.continuation = continuation
        entry.expiration = Task { [idleDuration] in
            try? await Task.sleep(for: idleDuration)
            guard !Task.isCancelled else { return }
            self.expire(key: key, task: lease.task)
        }
        entries[key] = entry
    }

    func recordFailure(sessionID: String?, message: String) {
        guard let sessionID else { return }
        fallbackSessions.insert(sessionID)
        let matching = entries.filter { $0.key.sessionID == sessionID }
        for (key, entry) in matching {
            entry.expiration?.cancel()
            entry.task.cancel(with: .normalClosure, reason: Data("transport_failure".utf8))
            entries.removeValue(forKey: key)
        }
        Log.network.warning("ChatGPT WebSocket disabled for session=\(sessionID) error=\(LogPrivacy.text(message, limit: 2_048))")
    }

    private func makeTask(_ request: URLRequest) -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return task
    }

    private func expire(key: Key, task: URLSessionWebSocketTask) {
        guard let entry = entries[key], entry.task === task, !entry.busy else { return }
        task.cancel(with: .normalClosure, reason: Data("idle_timeout".utf8))
        entries.removeValue(forKey: key)
    }
}

nonisolated enum OpenAIResponsesWebSocketBody {
    static func request(_ body: Data, continuing continuation: OpenAIResponsesWebSocketContinuation?) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw OpenAIClientError(message: "Invalid OpenAI Responses request body")
        }
        if let continuation, let delta = inputDelta(current: object, continuation: continuation) {
            object["previous_response_id"] = continuation.responseID
            object["input"] = delta
        }
        object["type"] = "response.create"
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func inputDelta(
        current: [String: Any],
        continuation: OpenAIResponsesWebSocketContinuation
    ) -> [Any]? {
        guard var previous = try? JSONSerialization.jsonObject(with: continuation.requestBody) as? [String: Any],
              let responseOutput = try? JSONSerialization.jsonObject(with: continuation.responseOutput) as? [Any]
        else { return nil }
        var comparableCurrent = current
        comparableCurrent.removeValue(forKey: "input")
        comparableCurrent.removeValue(forKey: "previous_response_id")
        previous.removeValue(forKey: "input")
        previous.removeValue(forKey: "previous_response_id")
        guard equal(comparableCurrent, previous) else { return nil }

        let previousInput = (try? JSONSerialization.jsonObject(with: continuation.requestBody) as? [String: Any])?["input"] as? [Any] ?? []
        let baseline = previousInput + responseOutput
        let currentInput = current["input"] as? [Any] ?? []
        guard currentInput.count >= baseline.count else { return nil }
        for index in baseline.indices where !equal(currentInput[index], baseline[index]) { return nil }
        return Array(currentInput.dropFirst(baseline.count))
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject([lhs]), JSONSerialization.isValidJSONObject([rhs]),
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else { return false }
        return left == right
    }
}

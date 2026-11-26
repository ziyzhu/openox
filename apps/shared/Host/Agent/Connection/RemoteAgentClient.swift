import Foundation

nonisolated enum RemoteAgentError: LocalizedError {
    case remote(String)
    case disconnected(String)
    case timedOut(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .remote(let message): message
        case .disconnected(let reason): "The agent disconnected: \(reason)"
        case .timedOut(let method): "The agent did not answer \(method) in time"
        case .invalidResponse(let method): "The agent returned an invalid \(method) response"
        }
    }
}

nonisolated struct RemoteAgentSelection: Equatable, Sendable {
    let model: AgentModelReference?
    let thinking: String?
}

nonisolated enum RemoteAgentInbound: Sendable {
    case event(JSONValue, seq: Int?)
    case prompt(JSONValue)
    case changed(JSONValue)
    case disconnected(String)
}

@MainActor
final class RemoteAgentClient {
    typealias ToolHandler = @MainActor (JSONValue) async -> JSONValue

    let endpoint: URL
    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var nextRequestID = 0
    private var pending: [Int: (method: String, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var listeners: [String: [UUID: @Sendable (RemoteAgentInbound) -> Void]] = [:]
    private var toolHandlers: [String: ToolHandler] = [:]
    private var opened: Set<String> = []
    private var applied: [String: RemoteAgentSelection] = [:]

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    func call(_ method: String, _ params: JSONValue = .object([:]), timeout: Duration = .seconds(120)) async throws -> JSONValue {
        let task = connectedSocket()
        nextRequestID += 1
        let id = nextRequestID
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method), "params": params])
        let data = try await message.encoded()
        let startedAt = ContinuousClock.now
        defer { Log.agent.info("RemoteAgent.call endpoint=\(self.endpoint.absoluteString) method=\(method) durationMs=\(TurnLatencyTrace.milliseconds(startedAt.duration(to: .now)))") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = (method, continuation)
            Task { @MainActor [weak self] in
                do { try await task.send(.data(data)) } catch { self?.fail(id, error) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.fail(id, RemoteAgentError.timedOut(method))
            }
        }
    }

    func inbound(for conversationID: String) -> AsyncStream<RemoteAgentInbound> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<RemoteAgentInbound>.makeStream()
        listeners[conversationID, default: [:]][token] = { continuation.yield($0) }
        continuation.onTermination = { _ in
            Task { @MainActor [weak self] in self?.listeners[conversationID]?[token] = nil }
        }
        return stream
    }

    func setToolHandler(_ handler: ToolHandler?, for conversationID: String) {
        toolHandlers[conversationID] = handler
    }

    func isOpen(_ conversationID: String) -> Bool { opened.contains(conversationID) }

    var isConnected: Bool { socket != nil }

    func appliedSelection(_ conversationID: String) -> RemoteAgentSelection? { applied[conversationID] }

    func markApplied(_ selection: RemoteAgentSelection?, for conversationID: String) { applied[conversationID] = selection }

    func markOpen(_ conversationID: String) { opened.insert(conversationID) }

    private func connectedSocket() -> URLSessionWebSocketTask {
        if let socket { return socket }
        let task = session.webSocketTask(with: endpoint)
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        task.resume()
        Log.agent.info("RemoteAgent.connect endpoint=\(endpoint.absoluteString)")
        receive(on: task)
        return task
    }

    private func receive(on task: URLSessionWebSocketTask) {
        Task { @MainActor [weak self] in
            while true {
                do {
                    let message = try await task.receive()
                    let data: Data = switch message {
                    case .data(let value): value
                    case .string(let value): Data(value.utf8)
                    @unknown default: Data()
                    }
                    let value = try await JSONValue.decode(data)
                    guard let self else { return }
                    handle(value, from: task)
                } catch {
                    self?.disconnect(task, reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func handle(_ value: JSONValue, from task: URLSessionWebSocketTask) {
        guard let fields = value.objectValue else { return }
        if let method = fields["method"]?.stringValue {
            let params = fields["params"] ?? .null
            if let id = fields["id"] { answer(id, method: method, params: params, on: task) } else { route(method, params) }
            return
        }
        guard let id = fields["id"]?.intValue, let entry = pending.removeValue(forKey: id) else { return }
        if let error = fields["error"]?.objectValue {
            entry.continuation.resume(throwing: RemoteAgentError.remote(error["message"]?.stringValue ?? "\(entry.method) failed"))
        } else {
            entry.continuation.resume(returning: fields["result"] ?? .null)
        }
    }

    private func route(_ method: String, _ params: JSONValue) {
        guard let conversationID = params.objectValue?["id"]?.stringValue else { return }
        let inbound: RemoteAgentInbound
        switch method {
        case "conversations.event": inbound = .event(params.objectValue?["event"] ?? .null, seq: params.objectValue?["seq"]?.intValue)
        case "conversations.prompt": inbound = .prompt(params)
        case "conversations.changed":
            if params.objectValue?["state"]?.stringValue == "exited" {
                opened.remove(conversationID)
                applied[conversationID] = nil
            }
            inbound = .changed(params)
        default: return
        }
        for listener in (listeners[conversationID] ?? [:]).values { listener(inbound) }
    }

    private func answer(_ id: JSONValue, method: String, params: JSONValue, on task: URLSessionWebSocketTask) {
        Task { @MainActor [weak self] in
            let response: JSONValue
            if method == "tools.call", let conversationID = params.objectValue?["id"]?.stringValue,
               let handler = self?.toolHandlers[conversationID] {
                response = .object(["jsonrpc": .string("2.0"), "id": id, "result": await handler(params)])
            } else {
                Log.agent.warning("RemoteAgent.request rejected method=\(method)")
                response = .object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
                    "code": .int(-32601), "message": .string("Ox conversation is not running"),
                ])])
            }
            do { try await task.send(.data(try await response.encoded())) }
            catch { Log.agent.error("RemoteAgent.request reply failed method=\(method) error=\(error.localizedDescription)") }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    private func disconnect(_ task: URLSessionWebSocketTask, reason: String) {
        guard socket === task else { return }
        socket = nil
        opened.removeAll()
        applied.removeAll()
        Log.agent.warning("RemoteAgent.disconnect endpoint=\(endpoint.absoluteString) reason=\(LogPrivacy.text(reason, limit: 200))")
        let failed = pending
        pending.removeAll()
        for entry in failed.values { entry.continuation.resume(throwing: RemoteAgentError.disconnected(reason)) }
        for listener in listeners.values.flatMap(\.values) { listener(.disconnected(reason)) }
    }
}

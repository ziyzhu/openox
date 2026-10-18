import CryptoKit
import Foundation
import UniformTypeIdentifiers

nonisolated enum RemoteMCPTransport: String, Codable, Sendable {
    case streamableHTTP = "streamable-http"
    case sse
}

nonisolated struct RemoteMCPDescriptor: Sendable {
    let id: String
    let endpoint: URL
    let transport: RemoteMCPTransport
    let name: String
    let version: String?
    let instructions: String?
    let icons: [RemoteMCPIcon]
    let tools: [RemoteMCPTool]

    static func serviceID(for endpoint: URL) -> String {
        let digest = SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return "mcp.\(digest.prefix(16))"
    }
}

nonisolated struct RemoteMCPIcon: Equatable, Sendable {
    let src: String
    let mimeType: String?
    let sizes: [String]
    let theme: String?
}

nonisolated struct RemoteMCPTool: Sendable {
    let name: String
    let title: String
    let description: String?
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
}

nonisolated struct RemoteMCPFile: Sendable {
    let data: Data
    let suggestedFilename: String
    let mimeType: String
}

nonisolated struct RemoteMCPToolResult: Sendable {
    let value: JSONValue
    let artifacts: [RemoteMCPFile]
}

nonisolated enum RemoteMCPError: LocalizedError, Sendable {
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case authorizationRequired(RemoteMCPAuthorizationChallenge)
    case oauth(String)
    case http(Int)
    case protocolError(String)
    case unsupportedProtocolVersion(String)
    case missingServerCapability(String)
    case server(Int, String)
    case tooManyTools
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a public HTTPS MCP endpoint."
        case .invalidResponse: "The MCP server returned an invalid response."
        case .responseTooLarge: "The MCP response exceeded the 4 MiB limit."
        case .authorizationRequired: "This MCP server requires authentication."
        case .oauth(let message): message
        case .http(let status): "The MCP server returned HTTP \(status)."
        case .protocolError(let message): "MCP protocol error: \(message)"
        case .unsupportedProtocolVersion(let version): "Ox supports MCP protocol versions 2024-11-05, 2025-03-26, 2025-06-18, and 2025-11-25; the server selected \(version)."
        case .missingServerCapability(let capability): "This MCP server does not declare the required \(capability) capability."
        case .server(let code, let message): "MCP server error \(code): \(message)"
        case .tooManyTools: "The MCP server exposed more than 500 tools."
        case .tool(let message): message
        }
    }
}

nonisolated final class RemoteMCPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor RemoteMCPClient {
    private enum State: Sendable {
        case disconnected
        case initializing
        case ready(protocolVersion: String)
    }

    private static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    private static let requestedProtocolVersion = supportedProtocolVersions.last!
    private static let maxResponseBytes = 4 * 1_024 * 1_024
    private static let maxTools = 500
    private static let maxToolPages = 20

    private let endpoint: URL
    private let session: URLSession
    private let legacySession: URLSession
    private var state: State = .disconnected
    private var transport: RemoteMCPTransport?
    private var sessionID: String?
    private var accessToken: String?
    private var nextRequestID = 1
    private var legacyMessageEndpoint: URL?
    private var legacyStreamTask: Task<Void, Never>?
    private var legacyEndpointContinuation: CheckedContinuation<URL, Error>?
    private var legacyEndpointTimeoutTask: Task<Void, Never>?
    private var legacyPendingResponses: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var legacyResponseTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var legacyConnectionError: Error?

    init(endpoint: URL, transport: RemoteMCPTransport? = nil, accessToken: String? = nil) {
        self.endpoint = endpoint
        self.transport = transport
        self.accessToken = accessToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: RemoteMCPRedirectDelegate(), delegateQueue: nil)
        let legacyConfiguration = configuration.copy() as! URLSessionConfiguration
        legacyConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        legacySession = URLSession(configuration: legacyConfiguration, delegate: RemoteMCPRedirectDelegate(), delegateQueue: nil)
    }

    func connect() async throws -> RemoteMCPDescriptor {
        guard case .disconnected = state else {
            throw RemoteMCPError.protocolError("connection is already active")
        }
        state = .initializing
        do {
            let result = try await request(
                method: "initialize",
                params: .object([
                    "protocolVersion": .string(Self.requestedProtocolVersion),
                    "capabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string("Ox"),
                        "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"),
                    ]),
                ]),
                protocolVersion: nil
            )
            guard let fields = result.objectValue,
                  let protocolVersion = fields["protocolVersion"]?.stringValue,
                  let serverInfo = fields["serverInfo"]?.objectValue,
                  let serverName = serverInfo["name"]?.stringValue,
                  !serverName.isEmpty else {
                throw RemoteMCPError.invalidResponse
            }
            guard Self.supportedProtocolVersions.contains(protocolVersion) else {
                throw RemoteMCPError.unsupportedProtocolVersion(protocolVersion)
            }
            guard let capabilities = fields["capabilities"]?.objectValue,
                  capabilities["tools"]?.objectValue != nil else {
                throw RemoteMCPError.missingServerCapability("tools")
            }
            state = .ready(protocolVersion: protocolVersion)
            try await notify(method: "notifications/initialized", params: .object([:]))
            let tools = try await listTools()
            guard let transport else { throw RemoteMCPError.protocolError("transport was not selected") }
            return RemoteMCPDescriptor(
                id: RemoteMCPDescriptor.serviceID(for: endpoint),
                endpoint: endpoint,
                transport: transport,
                name: serverName,
                version: serverInfo["version"]?.stringValue,
                instructions: fields["instructions"]?.stringValue,
                icons: Self.icons(serverInfo["icons"]),
                tools: tools
            )
        } catch {
            disconnect()
            throw error
        }
    }

    func callTool(name: String, arguments: JSONValue) async throws -> RemoteMCPToolResult {
        guard case .ready = state else { throw RemoteMCPError.protocolError("connection is not ready") }
        let result = try await request(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments])
        )
        guard let fields = result.objectValue else { throw RemoteMCPError.invalidResponse }
        if fields["isError"]?.boolValue == true {
            throw RemoteMCPError.tool(Self.contentText(fields["content"]) ?? "The MCP tool reported an error.")
        }
        let value = fields["structuredContent"] ?? fields["content"] ?? .null
        return RemoteMCPToolResult(value: value, artifacts: try Self.artifacts(fields["content"], value: value))
    }

    func disconnect() {
        state = .disconnected
        sessionID = nil
        legacyMessageEndpoint = nil
        legacyConnectionError = nil
        legacyStreamTask?.cancel()
        legacyStreamTask = nil
        failLegacyConnection(CancellationError())
        session.invalidateAndCancel()
        legacySession.invalidateAndCancel()
    }

    func setAccessToken(_ accessToken: String) {
        self.accessToken = accessToken
    }

    private func listTools() async throws -> [RemoteMCPTool] {
        var tools: [RemoteMCPTool] = []
        var names = Set<String>()
        var cursor: String?
        for _ in 0..<Self.maxToolPages {
            let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let result = try await request(method: "tools/list", params: params)
            guard let fields = result.objectValue, let values = fields["tools"]?.arrayValue else {
                throw RemoteMCPError.invalidResponse
            }
            for value in values {
                guard let fields = value.objectValue,
                      let name = fields["name"]?.stringValue,
                      !name.isEmpty,
                      names.insert(name).inserted,
                      let inputSchema = fields["inputSchema"]?.objectValue else {
                    throw RemoteMCPError.invalidResponse
                }
                tools.append(RemoteMCPTool(
                    name: name,
                    title: fields["title"]?.stringValue ?? name,
                    description: fields["description"]?.stringValue,
                    inputSchema: .object(inputSchema),
                    outputSchema: fields["outputSchema"]
                ))
                guard tools.count <= Self.maxTools else { throw RemoteMCPError.tooManyTools }
            }
            cursor = fields["nextCursor"]?.stringValue
            if cursor == nil { return tools }
        }
        throw RemoteMCPError.tooManyTools
    }

    private func request(method: String, params: JSONValue, protocolVersion: String? = nil) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1
        let response = try await send(
            .object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "method": .string(method),
                "params": params,
            ]),
            protocolVersion: protocolVersion ?? readyProtocolVersion,
            expectedID: id
        )
        return try Self.result(from: response, id: id)
    }

    private func notify(method: String, params: JSONValue) async throws {
        _ = try await send(
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string(method),
                "params": params,
            ]),
            protocolVersion: readyProtocolVersion,
            acceptsEmpty: true
        )
    }

    private var readyProtocolVersion: String? {
        if case .ready(let protocolVersion) = state { protocolVersion } else { nil }
    }

    private func send(
        _ payload: JSONValue,
        protocolVersion: String?,
        expectedID: Int? = nil,
        acceptsEmpty: Bool = false
    ) async throws -> JSONValue? {
        let selected = transport
        switch selected {
        case .sse:
            if legacyMessageEndpoint == nil { try await openLegacySSE() }
            return try await sendLegacy(payload, expectedID: expectedID)
        case .streamableHTTP, nil:
            do {
                let value = try await sendStreamableHTTP(
                    payload,
                    protocolVersion: protocolVersion,
                    expectedID: expectedID,
                    acceptsEmpty: acceptsEmpty
                )
                transport = .streamableHTTP
                return value
            } catch RemoteMCPError.http(let status) where selected == nil && [400, 404, 405].contains(status) {
                Log.service.info("RemoteMCP.transport fallback=legacySSE endpoint=\(LogPrivacy.url(endpoint.absoluteString)) status=\(status)")
                try await openLegacySSE()
                transport = .sse
                return try await sendLegacy(payload, expectedID: expectedID)
            }
        }
    }

    private func sendStreamableHTTP(
        _ payload: JSONValue,
        protocolVersion: String?,
        expectedID: Int?,
        acceptsEmpty: Bool
    ) async throws -> JSONValue? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw RemoteMCPError.invalidResponse }
        if let receivedSessionID = response.value(forHTTPHeaderField: "MCP-Session-Id"), !receivedSessionID.isEmpty {
            sessionID = receivedSessionID
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw RemoteMCPError.authorizationRequired(RemoteMCPAuthorizationChallenge(
                header: response.value(forHTTPHeaderField: "WWW-Authenticate")
            ))
        }
        let data = try await Self.responseData(bytes, expectedLength: response.expectedContentLength)
        guard (200...299).contains(response.statusCode) else {
            if [400, 404, 405].contains(response.statusCode),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data),
               let fields = value.objectValue,
               fields["jsonrpc"]?.stringValue == "2.0",
               let error = fields["error"]?.objectValue {
                throw Self.serverError(error)
            }
            throw RemoteMCPError.http(response.statusCode)
        }
        if data.isEmpty && acceptsEmpty { return nil }
        guard !data.isEmpty else { throw RemoteMCPError.invalidResponse }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            let values = try Self.sseValues(data)
            if let expectedID {
                return values.first { $0.objectValue?["id"]?.intValue == expectedID }
            }
            return values.last
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func openLegacySSE() async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (bytes, rawResponse) = try await legacySession.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw RemoteMCPError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw RemoteMCPError.authorizationRequired(RemoteMCPAuthorizationChallenge(
                header: response.value(forHTTPHeaderField: "WWW-Authenticate")
            ))
        }
        guard (200...299).contains(response.statusCode) else { throw RemoteMCPError.http(response.statusCode) }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.contains("text/event-stream") else { throw RemoteMCPError.invalidResponse }
        let messageEndpoint = try await withCheckedThrowingContinuation { continuation in
            legacyEndpointContinuation = continuation
            legacyConnectionError = nil
            legacyStreamTask = Task { [weak self] in
                await self?.receiveLegacyEvents(bytes)
            }
            legacyEndpointTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(30))
                    await self?.failLegacyConnection(RemoteMCPError.protocolError("legacy SSE endpoint timed out"))
                } catch {}
            }
        }
        legacyMessageEndpoint = messageEndpoint
        Log.service.info("RemoteMCP.transport ready=legacySSE endpoint=\(LogPrivacy.url(endpoint.absoluteString))")
    }

    private func receiveLegacyEvents(_ bytes: URLSession.AsyncBytes) async {
        var eventName: String?
        var dataLines: [String] = []
        var eventDataBytes = 0
        var lineData = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if byte == 0x0a {
                    if lineData.last == 0x0d { lineData.removeLast() }
                    guard let line = String(data: lineData, encoding: .utf8) else {
                        throw RemoteMCPError.invalidResponse
                    }
                    lineData.removeAll(keepingCapacity: true)
                    if line.isEmpty {
                        try receiveLegacyEvent(name: eventName, data: dataLines.joined(separator: "\n"))
                        eventName = nil
                        dataLines.removeAll(keepingCapacity: true)
                        eventDataBytes = 0
                    } else if line.hasPrefix("event:") {
                        eventName = Self.sseFieldValue(line, prefix: "event:")
                    } else if line.hasPrefix("data:") {
                        let value = Self.sseFieldValue(line, prefix: "data:")
                        eventDataBytes += value.utf8.count + (dataLines.isEmpty ? 0 : 1)
                        guard eventDataBytes <= Self.maxResponseBytes else { throw RemoteMCPError.responseTooLarge }
                        dataLines.append(value)
                    }
                } else {
                    guard lineData.count < Self.maxResponseBytes else { throw RemoteMCPError.responseTooLarge }
                    lineData.append(byte)
                }
            }
            if !lineData.isEmpty {
                if lineData.last == 0x0d { lineData.removeLast() }
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw RemoteMCPError.invalidResponse
                }
                if line.hasPrefix("event:") {
                    eventName = Self.sseFieldValue(line, prefix: "event:")
                } else if line.hasPrefix("data:") {
                    let value = Self.sseFieldValue(line, prefix: "data:")
                    eventDataBytes += value.utf8.count + (dataLines.isEmpty ? 0 : 1)
                    guard eventDataBytes <= Self.maxResponseBytes else { throw RemoteMCPError.responseTooLarge }
                    dataLines.append(value)
                }
            }
            try receiveLegacyEvent(name: eventName, data: dataLines.joined(separator: "\n"))
            throw RemoteMCPError.protocolError("legacy SSE connection closed")
        } catch {
            failLegacyConnection(error)
        }
    }

    private func receiveLegacyEvent(name: String?, data: String) throws {
        guard !data.isEmpty else { return }
        if name == "endpoint" {
            guard legacyMessageEndpoint == nil,
                  let messageEndpoint = Self.legacyMessageEndpoint(data, relativeTo: endpoint) else {
                throw RemoteMCPError.invalidResponse
            }
            legacyMessageEndpoint = messageEndpoint
            legacyEndpointTimeoutTask?.cancel()
            legacyEndpointTimeoutTask = nil
            legacyEndpointContinuation?.resume(returning: messageEndpoint)
            legacyEndpointContinuation = nil
            return
        }
        guard name == nil || name == "message",
              let value = JSONValue.parse(jsonString: data) else {
            throw RemoteMCPError.invalidResponse
        }
        guard let id = value.objectValue?["id"]?.intValue else {
            if let method = value.objectValue?["method"]?.stringValue {
                Log.service.info("RemoteMCP.legacy event ignored method=\(method)")
            }
            return
        }
        guard let continuation = legacyPendingResponses.removeValue(forKey: id) else { return }
        legacyResponseTimeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(returning: value)
    }

    private func sendLegacy(_ payload: JSONValue, expectedID: Int?) async throws -> JSONValue? {
        if let legacyConnectionError { throw legacyConnectionError }
        guard let messageEndpoint = legacyMessageEndpoint else { throw RemoteMCPError.invalidResponse }
        let body = try JSONEncoder().encode(payload)
        if let expectedID {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    legacyPendingResponses[expectedID] = continuation
                    legacyResponseTimeoutTasks[expectedID] = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(60))
                            await self?.timeoutLegacyResponse(expectedID)
                        } catch {}
                    }
                    Task { [weak self] in
                        await self?.postLegacyResponse(body, to: messageEndpoint, expectedID: expectedID)
                    }
                }
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelLegacyResponse(expectedID)
                }
            }
        }
        try await postLegacy(body, to: messageEndpoint)
        return nil
    }

    private func postLegacyResponse(_ body: Data, to messageEndpoint: URL, expectedID: Int) async {
        do {
            try await postLegacy(body, to: messageEndpoint)
        } catch {
            if let continuation = legacyPendingResponses.removeValue(forKey: expectedID) {
                legacyResponseTimeoutTasks.removeValue(forKey: expectedID)?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func postLegacy(_ body: Data, to messageEndpoint: URL) async throws {
        var request = URLRequest(url: messageEndpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (_, rawResponse) = try await legacySession.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw RemoteMCPError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw RemoteMCPError.authorizationRequired(RemoteMCPAuthorizationChallenge(
                header: response.value(forHTTPHeaderField: "WWW-Authenticate")
            ))
        }
        guard (200...299).contains(response.statusCode) else { throw RemoteMCPError.http(response.statusCode) }
    }

    private func cancelLegacyResponse(_ id: Int) {
        legacyResponseTimeoutTasks.removeValue(forKey: id)?.cancel()
        legacyPendingResponses.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func timeoutLegacyResponse(_ id: Int) {
        legacyResponseTimeoutTasks.removeValue(forKey: id)
        legacyPendingResponses.removeValue(forKey: id)?.resume(
            throwing: RemoteMCPError.protocolError("legacy SSE request timed out")
        )
    }

    private func failLegacyConnection(_ error: Error) {
        legacyConnectionError = error
        legacyEndpointTimeoutTask?.cancel()
        legacyEndpointTimeoutTask = nil
        legacyEndpointContinuation?.resume(throwing: error)
        legacyEndpointContinuation = nil
        for task in legacyResponseTimeoutTasks.values { task.cancel() }
        legacyResponseTimeoutTasks.removeAll()
        for continuation in legacyPendingResponses.values {
            continuation.resume(throwing: error)
        }
        legacyPendingResponses.removeAll()
    }

    private static func legacyMessageEndpoint(_ rawValue: String, relativeTo endpoint: URL) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value, relativeTo: endpoint)?.absoluteURL,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.scheme?.lowercased() == endpoint.scheme?.lowercased(),
              url.host?.lowercased() == endpoint.host?.lowercased(),
              effectivePort(url) == effectivePort(endpoint),
              WebFetchURLPolicy.allows(url) else { return nil }
        return url
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }

    private static func sseFieldValue(_ line: String, prefix: String) -> String {
        let value = line.dropFirst(prefix.count)
        return value.first == " " ? String(value.dropFirst()) : String(value)
    }

    private static func responseData(
        _ bytes: URLSession.AsyncBytes,
        expectedLength: Int64
    ) async throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedLength > 0 ? Int(min(expectedLength, Int64(maxResponseBytes))) : 0)
        for try await byte in bytes {
            guard data.count < maxResponseBytes else { throw RemoteMCPError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    private static func result(from response: JSONValue?, id: Int) throws -> JSONValue {
        guard let fields = response?.objectValue, fields["id"]?.intValue == id else {
            throw RemoteMCPError.invalidResponse
        }
        if let error = fields["error"]?.objectValue { throw serverError(error) }
        guard let result = fields["result"] else { throw RemoteMCPError.invalidResponse }
        return result
    }

    private static func serverError(_ error: [String: JSONValue]) -> RemoteMCPError {
        .server(error["code"]?.intValue ?? -32_000, error["message"]?.stringValue ?? "Unknown error")
    }

    private static func sseValues(_ data: Data) throws -> [JSONValue] {
        guard let text = String(data: data, encoding: .utf8) else { throw RemoteMCPError.invalidResponse }
        var values: [JSONValue] = []
        var eventData: [String] = []
        func appendEvent() throws {
            guard !eventData.isEmpty else { return }
            let joined = eventData.joined(separator: "\n")
            guard let value = JSONValue.parse(jsonString: joined) else { throw RemoteMCPError.invalidResponse }
            values.append(value)
            eventData.removeAll(keepingCapacity: true)
        }
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.isEmpty {
                try appendEvent()
            } else if rawLine.hasPrefix("data:") {
                eventData.append(String(rawLine.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        try appendEvent()
        guard !values.isEmpty else { throw RemoteMCPError.invalidResponse }
        return values
    }

    private static func contentText(_ value: JSONValue?) -> String? {
        value?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
    }

    private struct FileContent {
        let data: Data
        let filename: String?
        let mimeType: String
    }

    private static func artifacts(_ content: JSONValue?, value: JSONValue) throws -> [RemoteMCPFile] {
        let decoded = try content?.arrayValue?.compactMap(artifactContent) ?? []
        let structuredFilename = decoded.count == 1 ? resultFilename(value) : nil
        return decoded.enumerated().map { index, artifact in
            let filename = artifact.filename ?? structuredFilename ?? fallbackFilename(mimeType: artifact.mimeType, index: index, count: decoded.count)
            return RemoteMCPFile(data: artifact.data, suggestedFilename: filename, mimeType: artifact.mimeType)
        }
    }

    private static func artifactContent(_ value: JSONValue) throws -> FileContent? {
        guard let fields = value.objectValue, let type = fields["type"]?.stringValue else { return nil }
        if type == "image" {
            guard let encoded = fields["data"]?.stringValue,
                  let data = Data(base64Encoded: encoded),
                  let mimeType = fields["mimeType"]?.stringValue,
                  mimeType.lowercased().hasPrefix("image/") else {
                throw RemoteMCPError.protocolError("tool returned invalid image content")
            }
            return FileContent(data: data, filename: nil, mimeType: mimeType)
        }
        guard type == "resource", let resource = fields["resource"]?.objectValue else { return nil }
        let text = resource["text"]?.stringValue
        let blob = resource["blob"]?.stringValue
        guard (text == nil) != (blob == nil) else {
            throw RemoteMCPError.protocolError("tool returned invalid embedded resource content")
        }
        let data: Data
        if let text {
            data = Data(text.utf8)
        } else if let blob, let decoded = Data(base64Encoded: blob) {
            data = decoded
        } else {
            throw RemoteMCPError.protocolError("tool returned invalid embedded resource data")
        }
        let mimeType = resource["mimeType"]?.stringValue ?? (text == nil ? "application/octet-stream" : "text/plain")
        let filename = resource["uri"]?.stringValue.flatMap {
            URL(string: $0)?.lastPathComponent.removingPercentEncoding
        }
        return FileContent(data: data, filename: filename?.isEmpty == false ? filename : nil, mimeType: mimeType)
    }

    private static func resultFilename(_ value: JSONValue) -> String? {
        let fields = value.objectValue
        return fields?["filename"]?.stringValue ?? fields?["result"]?.objectValue?["filename"]?.stringValue
    }

    private static func fallbackFilename(mimeType: String, index: Int, count: Int) -> String {
        let stem = count == 1 ? "FileItem" : "FileItem \(index + 1)"
        guard let suffix = UTType(mimeType: mimeType)?.preferredFilenameExtension else { return "\(stem).bin" }
        return "\(stem).\(suffix)"
    }

    private static func icons(_ value: JSONValue?) -> [RemoteMCPIcon] {
        value?.arrayValue?.prefix(32).compactMap { value in
            guard let fields = value.objectValue,
                  let src = fields["src"]?.stringValue,
                  !src.isEmpty else { return nil }
            return RemoteMCPIcon(
                src: src,
                mimeType: fields["mimeType"]?.stringValue,
                sizes: fields["sizes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                theme: fields["theme"]?.stringValue
            )
        } ?? []
    }
}

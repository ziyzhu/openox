import Foundation

@MainActor
final class RemoteMCPService {
    private struct Connection {
        let client: RemoteMCPClient
        let descriptor: RemoteMCPDescriptor
        let requiresAuthorization: Bool
        let isAuthorized: Bool
    }

    private var client: RemoteMCPClient?
    private var activationTask: Task<Connection, Error>?
    private var activationID = UUID()
    private(set) var requiresAuthorization: Bool
    private(set) var isAuthorized: Bool
    var isActive: Bool { client != nil || activationTask != nil }
    var auth: Service.Auth { requiresAuthorization ? (isAuthorized ? .authorized : .authorizationRequired) : .notRequired }

    let endpoint: URL
    let transport: RemoteMCPTransport?
    private(set) var descriptor: RemoteMCPDescriptor?

    init(endpoint: URL, transport: RemoteMCPTransport?) {
        self.endpoint = endpoint
        self.transport = transport
        self.requiresAuthorization = RemoteMCPOAuth.hasCredential(endpoint: endpoint)
        self.isAuthorized = false
    }

    nonisolated static func endpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        let normalized = hasScheme ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.absoluteString == normalized,
              url.fragment == nil,
              url.scheme?.lowercased() == "https" || allowsDevelopmentHTTP(url),
              WebFetchURLPolicy.allows(url) else { throw RemoteMCPError.invalidEndpoint }
        return url
    }

    func resolve(allowsAuthorization: Bool = false, refresh: Bool = false) async throws -> RemoteMCPDescriptor {
        if let descriptor, !refresh { return descriptor }
        guard endpoint.scheme?.lowercased() == "https" || Self.allowsDevelopmentHTTP(endpoint),
              WebFetchURLPolicy.allows(endpoint) else {
            throw RemoteMCPError.invalidEndpoint
        }
        if let transport {
            Log.service.info("RemoteMCP.transport hint=\(transport.rawValue) endpoint=\(LogPrivacy.url(endpoint.absoluteString))")
        }
        let connection = try await Self.open(
            endpoint: endpoint,
            transport: transport,
            allowsAuthorization: allowsAuthorization
        )
        await connection.client.disconnect()
        descriptor = connection.descriptor
        requiresAuthorization = connection.requiresAuthorization
        isAuthorized = connection.isAuthorized
        let authorization = switch auth {
        case .authorized: "authorized"
        case .authorizationRequired: "required"
        default: "notRequired"
        }
        Log.service.info("RemoteMCP.connect id=\(connection.descriptor.id) endpoint=\(LogPrivacy.url(endpoint.absoluteString)) tools=\(connection.descriptor.tools.count) icons=\(connection.descriptor.icons.count) authorization=\(authorization) active=false")
        return connection.descriptor
    }

    private static func open(
        endpoint: URL,
        transport: RemoteMCPTransport?,
        allowsAuthorization: Bool
    ) async throws -> Connection {
        guard await WebFetchURLPolicy.allowsResolved(endpoint, allowsTailscale: true) else { throw RemoteMCPError.invalidEndpoint }
        var token: String?
        do {
            token = try await RemoteMCPOAuth.accessToken(endpoint: endpoint)
        } catch {
            Log.service.error("RemoteMCP.oauth refresh failed endpoint=\(LogPrivacy.url(endpoint.absoluteString)) error=\(error.localizedDescription)")
        }
        var requiresAuthorization = RemoteMCPOAuth.hasCredential(endpoint: endpoint)
        var isAuthorized = false
        var client = RemoteMCPClient(endpoint: endpoint, transport: transport, accessToken: token)
        let descriptor: RemoteMCPDescriptor
        do {
            descriptor = try await client.connect()
            isAuthorized = token != nil
        } catch RemoteMCPError.authorizationRequired(let challenge) {
            requiresAuthorization = true
            await client.disconnect()
            let refreshed = token == nil ? nil : try? await RemoteMCPOAuth.accessToken(endpoint: endpoint, forceRefresh: true)
            if let refreshed {
                client = RemoteMCPClient(endpoint: endpoint, transport: transport, accessToken: refreshed)
                do {
                    descriptor = try await client.connect()
                    isAuthorized = true
                } catch RemoteMCPError.authorizationRequired(let refreshedChallenge) {
                    await client.disconnect()
                    guard allowsAuthorization else { throw RemoteMCPError.authorizationRequired(refreshedChallenge) }
                    let accessToken = try await RemoteMCPOAuth.authorize(endpoint: endpoint, challenge: refreshedChallenge)
                    client = RemoteMCPClient(endpoint: endpoint, transport: transport, accessToken: accessToken)
                    descriptor = try await client.connect()
                    isAuthorized = true
                }
            } else {
                guard allowsAuthorization else { throw RemoteMCPError.authorizationRequired(challenge) }
                let accessToken = try await RemoteMCPOAuth.authorize(endpoint: endpoint, challenge: challenge)
                client = RemoteMCPClient(endpoint: endpoint, transport: transport, accessToken: accessToken)
                descriptor = try await client.connect()
                isAuthorized = true
            }
        }
        if !requiresAuthorization {
            requiresAuthorization = await RemoteMCPOAuth.advertisesAuthorization(endpoint: endpoint)
        }
        return Connection(
            client: client,
            descriptor: descriptor,
            requiresAuthorization: requiresAuthorization,
            isAuthorized: isAuthorized || !requiresAuthorization
        )
    }

    var detailCapabilities: ServiceDetailCapabilities {
        ServiceDetailCapabilities(
            authentication: .mcp,
            attachmentData: .remote,
            showsDomain: true,
            supportsPageInspection: false,
            supportsWebsiteDataManagement: false,
            supportsFolderAccess: false,
            supportsRemoteManagement: true
        )
    }

    var authorizationTitle: String? {
        guard requiresAuthorization else { return nil }
        return RemoteMCPOAuth.hasCredential(endpoint: endpoint) ? "Reauthorize" : "Authorize"
    }

    func authorize() async throws -> RemoteMCPDescriptor {
        guard let descriptor else {
            return try await resolve(allowsAuthorization: true)
        }
        let token: String
        if RemoteMCPOAuth.hasCredential(endpoint: endpoint) {
            token = try await RemoteMCPOAuth.reauthorize(endpoint: endpoint)
        } else {
            token = try await RemoteMCPOAuth.authorize(
                endpoint: endpoint,
                challenge: RemoteMCPAuthorizationChallenge(header: nil)
            )
        }
        let validation = RemoteMCPClient(
            endpoint: endpoint,
            transport: descriptor.transport,
            accessToken: token
        )
        let validatedDescriptor = try await validation.connect()
        await validation.disconnect()
        guard validatedDescriptor.id == descriptor.id else { throw RemoteMCPError.invalidResponse }
        requiresAuthorization = true
        isAuthorized = true
        self.descriptor = validatedDescriptor
        Log.service.info("RemoteMCP.authorize completed id=\(descriptor.id) active=false")
        return validatedDescriptor
    }

    @discardableResult
    func activate() async throws -> RemoteMCPClient {
        if let client { return client }
        if let activationTask {
            let connection = try await activationTask.value
            return connection.client
        }
        guard let descriptor else { throw RemoteMCPError.protocolError("tools are not loaded") }
        let id = UUID()
        activationID = id
        let resolvedTransport = descriptor.transport
        let task = Task {
            try await Self.open(endpoint: endpoint, transport: resolvedTransport, allowsAuthorization: false)
        }
        activationTask = task
        do {
            let connection = try await task.value
            activationTask = nil
            guard activationID == id else {
                await connection.client.disconnect()
                throw CancellationError()
            }
            guard connection.descriptor.id == descriptor.id else {
                await connection.client.disconnect()
                throw RemoteMCPError.invalidResponse
            }
            client = connection.client
            requiresAuthorization = connection.requiresAuthorization
            isAuthorized = connection.isAuthorized
            Log.service.info("RemoteMCP.activate id=\(descriptor.id)")
            return connection.client
        } catch {
            activationTask = nil
            Log.service.error("RemoteMCP.activate failed id=\(descriptor.id) error=\(error.localizedDescription)")
            throw error
        }
    }

    func deactivate() async {
        activationID = UUID()
        activationTask?.cancel()
        activationTask = nil
        guard let client else { return }
        self.client = nil
        await client.disconnect()
        Log.service.info("RemoteMCP.deactivate id=\(descriptor?.id ?? RemoteMCPDescriptor.serviceID(for: endpoint))")
    }

    func invoke(
        service: Service,
        actionID: String,
        args: JSONValue,
        approve: @MainActor (_ action: String, _ args: Any?) async -> Bool,
        receiveFiles: @MainActor ([RemoteMCPFile]) async throws -> Void = { _ in }
    ) async -> Result<JSONValue, Error> {
        let name = "\(service.domain):\(actionID)"
        do { try await service.manager.requireInvocationAccess(for: service) }
        catch { return .failure(error) }
        guard let action = service.definition.action(actionID),
              let inputSchema = action.inputSchema,
              let outputSchema = action.outputSchema else {
            return .failure(Service.InvokeError.unknown(name))
        }
        let inputViolations = JSONSchemaValidator.validate(args, against: inputSchema, definitions: [:])
        guard inputViolations.isEmpty else { return .failure(Service.InvokeError.invalidInput(name, inputViolations)) }
        let allowed = await approve(name, args.toAny())
        Log.service.info("RemoteMCP.invoke approval name=\(name) allow=\(allowed)")
        guard allowed else { return .failure(Service.InvokeError.denied(name)) }
        do {
            try await service.manager.requireInvocationAccess(for: service)
            let keepActive = isActive
            let client = try await activate()
            defer {
                if !keepActive { Task { await self.deactivate() } }
            }
            try await service.manager.requireInvocationAccess(for: service)
            let result = try await client.callTool(name: actionID, arguments: args)
            let outputViolations = JSONSchemaValidator.validate(result.value, against: outputSchema, definitions: [:])
            guard outputViolations.isEmpty else { return .failure(Service.InvokeError.invalidOutput(name, outputViolations)) }
            try await receiveFiles(result.files)
            service.setAuth(.authorized)
            Log.service.info("RemoteMCP.invoke completed name=\(name) files=\(result.files.count)")
            return .success(result.value)
        } catch RemoteMCPError.authorizationRequired {
            requiresAuthorization = true
            do {
                try await service.manager.requireInvocationAccess(for: service)
                guard let accessToken = try await RemoteMCPOAuth.accessToken(endpoint: endpoint, forceRefresh: true) else {
                    throw RemoteMCPError.authorizationRequired(RemoteMCPAuthorizationChallenge(header: nil))
                }
                let client = try await activate()
                await client.setAccessToken(accessToken)
                try await service.manager.requireInvocationAccess(for: service)
                let result = try await client.callTool(name: actionID, arguments: args)
                let outputViolations = JSONSchemaValidator.validate(result.value, against: outputSchema, definitions: [:])
                guard outputViolations.isEmpty else { return .failure(Service.InvokeError.invalidOutput(name, outputViolations)) }
                try await receiveFiles(result.files)
                service.setAuth(.authorized)
                Log.service.info("RemoteMCP.invoke completed-after-refresh name=\(name) files=\(result.files.count)")
                return .success(result.value)
            } catch {
                service.setAuth(.notAuthorized)
                Log.service.error("RemoteMCP.invoke refresh failed name=\(name) error=\(error.localizedDescription)")
                return .failure(error)
            }
        } catch {
            Log.service.error("RemoteMCP.invoke failed name=\(name) error=\(error.localizedDescription)")
            return .failure(error)
        }
    }

    func remove() async {
        await deactivate()
        RemoteMCPOAuth.clear(endpoint: endpoint)
        descriptor = nil
        requiresAuthorization = false
        isAuthorized = false
        Log.service.info("RemoteMCP.remove id=\(RemoteMCPDescriptor.serviceID(for: endpoint))")
    }

    nonisolated static func allowsDevelopmentHTTP(_ endpoint: URL) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        endpoint.scheme?.lowercased() == "http"
        #else
        false
        #endif
    }
}

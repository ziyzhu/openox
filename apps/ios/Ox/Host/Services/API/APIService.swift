import Foundation

nonisolated final class APIServiceHTTP: NSObject, URLSessionTaskDelegate, Sendable {
    struct Response: Sendable {
        let status: Int
        let data: Data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    #if targetEnvironment(simulator)
    nonisolated(unsafe) static var fixtureProtocol: URLProtocol.Type?
    #endif

    static func send(_ request: URLRequest, maximumBytes: Int = 2_000_000) async throws -> Response {
        let configuration = URLSessionConfiguration.ephemeral
        #if targetEnvironment(simulator)
        if let fixtureProtocol { configuration.protocolClasses = [fixtureProtocol] }
        #endif
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: APIServiceHTTP(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw APIServiceError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw APIServiceError.responseTooLarge }
                data.append(byte)
            }
            return Response(status: response.statusCode, data: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIServiceError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let failure = error as NSError
            Log.service.error("APIServiceHTTP.transport failed domain=\(failure.domain) code=\(failure.code)")
            throw APIServiceError.invalidResponse
        }
    }
}

@MainActor
final class APIService {
    let authorization: APIServiceAuthorization
    private let definition: ServiceDefinition
    private let runtime = VirtualMachine()
    var source: Service.Resolved?

    init(definition: ServiceDefinition) throws {
        self.definition = definition
        authorization = try APIServiceAuthorization(definition: definition)
    }

    var detailCapabilities: ServiceDetailCapabilities {
        ServiceDetailCapabilities(authentication: .service, attachmentData: .remote, showsDomain: true,
            showsSkills: true, supportsPageInspection: false, supportsWebsiteDataManagement: false,
            supportsFolderAccess: false, supportsRemoteManagement: false)
    }

    func invoke(service: Service, actionID: String, args: JSONValue,
                approve: @MainActor (String, Any?) async -> Bool) async -> Result<JSONValue, Error> {
        let name = definition.qualifiedActionName(actionID)
        do {
            guard let action = definition.action(actionID), let input = action.inputSchema,
                  let output = action.outputSchema else { throw Service.InvokeError.unknown(name) }
            let violations = JSONSchemaValidator.validate(args, against: input, definitions: definition.definitions)
            guard violations.isEmpty else { throw Service.InvokeError.invalidInput(name, violations) }
            if action.requireApproval {
                guard await approve(name, args.toAny()) else { throw Service.InvokeError.denied(name) }
            }
            try Task.checkCancellation()
            if action.requireAuth && !authorization.isConfigured { throw APIServiceError.authorizationRequired }
            if source == nil, let fetched = await service.manager.fetch(domain: definition.domain) {
                source = Service.Resolved(actions: fetched.actions, skills: fetched.skills)
            }
            guard let source else {
                throw Service.InvokeError.invalidContract(name)
            }
            let script = Self.installer + "\n" + source.actions + "\n"
                + "return await __invokeAPI(\(JSONValue.string(actionID).jsonString()), \(args.jsonString()), \(JSONValue.array(definition.actions.map { .string($0.id) }).jsonString()));"
            let result = try await runtime.runAPI(source: script) { [self] args in
                do {
                    return try await request(args, authenticated: action.requireAuth, allowsMutation: action.requireApproval)
                } catch APIServiceError.authorizationRequired {
                    service.setAuth(.observed(Service.AuthObservation(value: .signedOut, observedAt: Date())))
                    throw APIServiceError.authorizationRequired
                }
            }
            let value = result.value ?? .null
            let outputErrors = JSONSchemaValidator.validate(value, against: output, definitions: definition.definitions)
            guard outputErrors.isEmpty else { throw Service.InvokeError.invalidOutput(name, outputErrors) }
            if action.requireAuth {
                service.setAuth(.observed(Service.AuthObservation(value: .signedIn, observedAt: Date())))
            }
            Log.service.info("APIService.invoke done service=\(definition.domain) action=\(actionID)")
            return .success(value)
        } catch {
            if let error = error as? APIServiceError, case .authorizationRequired = error {
                service.setAuth(.observed(Service.AuthObservation(value: .signedOut, observedAt: Date())))
            }
            Log.service.error("APIService.invoke failed service=\(definition.domain) action=\(actionID)")
            return .failure(error)
        }
    }

    func request(_ args: JSONValue, authenticated: Bool, allowsMutation: Bool) async throws -> JSONValue {
        guard let raw = args.objectValue, let path = raw["path"]?.stringValue,
              let base = definition.baseURL, let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil, url.fragment == nil,
              !url.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains(".."),
              url.standardized.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else {
            throw APIServiceError.destinationDenied
        }
        let method = raw["method"]?.stringValue?.uppercased() ?? "GET"
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method) else { throw APIServiceError.invalidRequest }
        guard allowsMutation || ["GET", "HEAD"].contains(method) else { throw APIServiceError.mutationDenied }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIServiceError.invalidRequest }
        if let query = raw["query"]?.objectValue {
            components.queryItems = (components.queryItems ?? []) + query.sorted { $0.key < $1.key }.compactMap { key, value in
                guard value != .null else { return nil }
                return URLQueryItem(name: key, value: value.stringValue ?? value.jsonString())
            }
        }
        guard let destination = components.url else { throw APIServiceError.invalidRequest }
        var request = URLRequest(url: destination)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json = raw["json"] {
            guard !["GET", "HEAD"].contains(method) else { throw APIServiceError.invalidRequest }
            request.httpBody = try JSONEncoder().encode(json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated { request = try await authorization.prepare(request) }
        let response = try await APIServiceHTTP.send(request)
        Log.service.info("APIService.request service=\(definition.domain) method=\(method) status=\(response.status) bytes=\(response.data.count)")
        if response.status == 401, authenticated {
            authorization.rejectCredential()
            throw APIServiceError.authorizationRequired
        }
        guard (200..<300).contains(response.status) else { throw APIServiceError.http(response.status) }
        if response.data.isEmpty { return .null }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: response.data) else { throw APIServiceError.invalidResponse }
        return value
    }

    private static let installer = #"""
    const __handlers = new Map();
    let __installed = false;
    const window = Object.freeze({ ox: Object.freeze({ install(version, install) {
      if (__installed || version !== 1 || typeof install !== 'function') throw new Error('Invalid API installer');
      __installed = true;
      const result = install(Object.freeze({
        action(name, handler) {
          if (typeof name !== 'string' || __handlers.has(name) || typeof handler?.invoke !== 'function') throw new Error('Invalid API action');
          __handlers.set(name, handler.invoke);
        },
        request: args => __apiRequest(args),
        log: (...args) => console.log(...args),
        lib: Object.freeze({ cleanText: value => String(value ?? '').replace(/\s+/g, ' ').trim() })
      }));
      if (result?.then) throw new Error('API installer must be synchronous');
    } }) });
    const __invokeAPI = async (name, args, declared) => {
      if (!__installed || declared.length !== __handlers.size || declared.some(id => !__handlers.has(id))) throw new Error('API action registration mismatch');
      return await __handlers.get(name)(args);
    };
    """#
}

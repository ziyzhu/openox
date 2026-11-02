import Foundation

extension Service {
    enum AccessRequestOutcome: Equatable {
        case completed
        case incomplete
    }

    func accessResult() -> JSONValue {
        let completion: String
        if auth.observation?.evidence == .configured {
            completion = "configured"
        } else if auth == .authorized {
            completion = "authorized"
        } else {
            completion = "verified"
        }
        return .object([
            "domain": .string(domain),
            "completed": .bool(true),
            "signedIn": .bool(loginState.isAuthenticated),
            "state": .string(loginState.rawValue),
            "completion": .string(completion),
        ])
    }

    var supportsAuthentication: Bool {
        isAPIService || isMCPService || iOSService?.requiresPermission == true
    }

    @discardableResult
    func checkAccess(policy: AccessPolicy = .cached, reason: LoginProbeReason, preflight: UUID? = nil) async -> LoginState {
        await access.check(self, policy: policy, reason: reason, preflight: preflight) {
            try await self.readAccess()
        }
    }

    func readAccess() async throws -> Auth {
        if let iOS = iOSService { return await iOS.checkAccess() }
        if let apiService { return try await apiService.authorization.checkAccess(previous: auth.observation) }
        if let mcp = remoteMCPService {
            _ = try await mcp.resolve(refresh: true)
            return mcp.auth
        }
        return .notRequired
    }

    var accessActionLabel: String {
        auth == .authorizationRequired ? "Set Up" : "Manage"
    }

    func awaitAuthenticationAvailability(name: String) async throws {
        guard auth.isLoggingIn else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard auth.isLoggingIn else {
                    continuation.resume()
                    return
                }
                let waiter = AuthenticationWaiter(id: id, name: name, continuation: continuation)
                authenticationWaiters.append(waiter)
                Log.service.info("Service.auth barrier queued domain=\(domain) id=\(waiter.id.uuidString.prefix(8)) name=\(name) waiters=\(authenticationWaiters.count)")
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAuthenticationWaiter(id: id)
            }
        }
    }

    func releaseAuthenticationWaiters() {
        let waiters = authenticationWaiters
        authenticationWaiters.removeAll()
        for waiter in waiters { waiter.settle(.success(())) }
        if !waiters.isEmpty {
            Log.service.info("Service.auth barrier released domain=\(domain) count=\(waiters.count) auth=\(auth.logLabel)")
        }
    }

    private func cancelAuthenticationWaiter(id: UUID) {
        guard let index = authenticationWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = authenticationWaiters.remove(at: index)
        waiter.settle(.failure(CancellationError()))
        Log.service.info("Service.auth barrier cancelled domain=\(domain) id=\(waiter.id.uuidString.prefix(8)) name=\(waiter.name) waiters=\(authenticationWaiters.count)")
    }

    @discardableResult
    func requestAccess(source: AuthLoginSource = .serviceDetail) async throws -> AccessRequestOutcome {
        try await access.request(self) {
            try await self.performAccessRequest(source: source)
        }
    }

    private func performAccessRequest(source: AuthLoginSource) async throws -> AccessRequestOutcome {
        let policy: AccessPolicy = source == .conversationCard ? .cached : .current
        if let iOS = iOSService {
            let current = await iOS.permissionState()
            _ = await iOS.updatePermission(from: current)
            setAuth(await iOS.checkAccess())
            return loginState.isAuthenticated ? .completed : .incomplete
        }
        if let mcp = remoteMCPService {
            await checkAccess(policy: policy, reason: .modelLogin)
            if source != .serviceDetail, loginState.isAuthenticated { return .completed }
            let descriptor = try await mcp.authorize()
            applyResolvedDefinition(ServiceDefinition(mcp: descriptor, metadata: definition), reason: .serviceDetail)
            return loginState.isAuthenticated ? .completed : .incomplete
        }
        guard let apiService else {
            throw RuntimeError.bridge("Website authentication uses the service login action, followed by listSessions")
        }
        await checkAccess(policy: policy, reason: .modelLogin)
        guard !Task.isCancelled else { return .incomplete }
        guard !loginState.isAuthenticated, auth != .notRequired else { return .completed }
        guard !auth.isLoggingIn else { return .incomplete }
        let previous = auth.observation
        setAuth(.loggingIn(previous: previous))
        do {
            try await APIServiceLogin.present(self)
            setAuth(try await apiService.authorization.checkAccess(previous: nil))
        } catch is CancellationError {
            setAuth(try await apiService.authorization.checkAccess(previous: nil))
        } catch {
            setAuth(.unavailable(previous: previous, error: error.localizedDescription))
            throw error
        }
        return loginState.isAuthenticated ? .completed : .incomplete
    }

    func signOut() async {
        if let apiService {
            apiService.authorization.clear()
            await checkAccess(policy: .current, reason: .clearWebsiteData)
            return
        }
        await clearWebData()
    }

    func clearWebData() async {
        let started = Date()
        Log.service.info("Service.clearWebData start domain=\(domain) auth=\(auth.logLabel)")
        await manager.clearWebsiteData(domain: domain)
        await checkAccess(policy: .current, reason: .clearWebsiteData)
        Log.service.info("Service.clearWebData done domain=\(domain) auth=\(auth.logLabel) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }
}

@MainActor
final class ServiceAccess {
    private static let maxAge: TimeInterval = 30 * 60
    private static let unavailableRetryInterval: TimeInterval = 30
    private(set) var loginPreflight: UUID?
    private var checkedAt: Date?
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var requestTask: Task<Service.AccessRequestOutcome, Error>?

    func request(_ service: Service, operation: @escaping @MainActor () async throws -> Service.AccessRequestOutcome) async throws -> Service.AccessRequestOutcome {
        if let requestTask { return try await requestTask.value }
        let task = Task { @MainActor in
            do {
                return try await operation()
            } catch {
                Log.service.warning("Service.access request failed domain=\(service.domain) error=\(LogPrivacy.text(error.localizedDescription))")
                throw error
            }
        }
        requestTask = task
        defer { requestTask = nil }
        return try await task.value
    }

    func didUpdate(_ auth: Service.Auth) {
        revision = UUID()
        loginPreflight = nil
        switch auth {
        case .observed(let observation): checkedAt = observation.observedAt
        case .authorized, .notRequired, .unavailable: checkedAt = Date()
        default: break
        }
    }

    func check(_ service: Service, policy: Service.AccessPolicy, reason: Service.LoginProbeReason, preflight: UUID? = nil, read: @escaping @MainActor () async throws -> Service.Auth) async -> Service.LoginState {
        guard !Task.isCancelled else { return service.loginState }
        if let preflight, preflight == loginPreflight, isFresh(service.auth) {
            loginPreflight = nil
            Log.service.info("Service.access preflight domain=\(service.domain) reason=\(reason.rawValue)")
            return service.loginState
        }
        if service.auth.isLoggingIn {
            let previousCheck = checkedAt
            do {
                try await service.awaitAuthenticationAvailability(name: "checkAccess:\(reason.rawValue)")
            } catch {
                return service.loginState
            }
            return await check(service, policy: checkedAt != previousCheck ? .cached : policy, reason: reason, read: read)
        }
        if let task {
            Log.service.info("Service.access joined domain=\(service.domain) reason=\(reason.rawValue)")
            await task.value
            preparePreflight(service, policy: policy, reason: reason)
            return service.loginState
        }
        let local = service.isIOSService || service.isAPIService
        if !local, policy == .cached, isFresh(service.auth) {
            Log.service.info("Service.access cached domain=\(service.domain) reason=\(reason.rawValue) auth=\(service.auth.logLabel)")
            return service.loginState
        }
        let previous = service.auth
        if !local { service.setAuth(.checking(previous: previous.observation)) }
        let revision = revision
        let started = Date()
        Log.service.info("Service.access start domain=\(service.domain) reason=\(reason.rawValue) policy=\(policy.rawValue)")
        let task = Task { @MainActor in
            let next: Service.Auth
            do {
                next = try await read()
            } catch is CancellationError {
                next = previous
            } catch RemoteMCPError.authorizationRequired {
                next = .authorizationRequired
            } catch {
                next = .unavailable(previous: previous.observation, error: error.localizedDescription)
                Log.service.warning("Service.access unavailable domain=\(service.domain) reason=\(reason.rawValue) error=\(LogPrivacy.text(error.localizedDescription))")
            }
            guard self.revision == revision else { return }
            service.setAuth(next)
        }
        self.task = task
        await task.value
        self.task = nil
        preparePreflight(service, policy: policy, reason: reason)
        Log.service.info("Service.access done domain=\(service.domain) reason=\(reason.rawValue) auth=\(service.auth.logLabel) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return service.loginState
    }

    private func preparePreflight(_ service: Service, policy: Service.AccessPolicy, reason: Service.LoginProbeReason) {
        if policy == .current, reason == .modelLogin, isFresh(service.auth), !Task.isCancelled {
            loginPreflight = revision
        }
    }

    private func isFresh(_ auth: Service.Auth) -> Bool {
        switch auth {
        case .observed, .authorized, .notRequired:
            return checkedAt.map { Date().timeIntervalSince($0) < Self.maxAge } ?? false
        case .unavailable:
            return checkedAt.map { Date().timeIntervalSince($0) < Self.unavailableRetryInterval } ?? false
        default:
            return false
        }
    }
}

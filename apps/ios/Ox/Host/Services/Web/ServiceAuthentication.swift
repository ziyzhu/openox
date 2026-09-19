import Foundation

extension Service {
    var supportsAuthentication: Bool {
        isMCPService || iOSService?.requiresPermission == true || supportsWebAuthentication
    }

    private var supportsWebAuthentication: Bool {
        definition.action(Manifest.SIGN_IN_STATE_ACTION_ID, includingStandard: true) != nil
    }

    @discardableResult
    func checkAccess(policy: AccessPolicy = .cached, reason: SignInProbeReason, preflight: UUID? = nil) async -> SignInState {
        await access.check(self, policy: policy, reason: reason, preflight: preflight) {
            try await self.readAccess()
        }
    }

    func readAccess() async throws -> Auth {
        if let iOS = iOSService { return await iOS.checkAccess() }
        if let mcp = remoteMCPService {
            _ = try await mcp.resolve(refresh: true)
            return mcp.requiresAuthorization ? (mcp.isAuthorized ? .authorized : .authorizationRequired) : .notRequired
        }
        guard supportsWebAuthentication, let webService else { return .notRequired }
        return try await webService.checkAccess(service: self)
    }

    var accessActionLabel: String {
        auth == .authorizationRequired ? "Set Up" : "Manage"
    }

    func getSignInState(in session: ServiceFlowSession) async -> GetSignInStateResult {
        let result = await session.invoke(
            Manifest.SIGN_IN_STATE_ACTION_ID,
            args: .object([:]),
            role: .authenticationProbe
        )
        guard case .success(let value) = result else {
            return GetSignInStateResult(.error("getSignInState invoke failed"))
        }
        return GetSignInStateResult(Manifest.getSignInStateOutcome(value))
    }

    private func fetchAuthURL(in session: ServiceFlowSession) async -> URL? {
        let result = await session.invoke(
            Manifest.SIGN_IN_URL_ACTION_ID,
            args: .object([:]),
            role: .authenticationProbe
        )
        guard case .success(let value) = result else { return nil }
        return Manifest.authURL(value).flatMap { URL(string: $0) }
    }

    func awaitAuthenticationAvailability(name: String) async throws {
        guard auth.isSigningIn else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard auth.isSigningIn else {
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

    func attemptSilentSignIn(reason: SignInProbeReason) async {
        guard webService != nil, case .observed(let previous) = auth,
              previous.value == .signedOut else { return }
        if let task = silentSignInTask {
            Log.service.info("Service.silentAuth joined domain=\(domain) reason=\(reason.rawValue)")
            await task.value
            return
        }
        guard !attemptedSilentSignIn,
              auth.observation == previous else { return }
        attemptedSilentSignIn = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.manager.sessionCoordinator.run(for: self, kind: .authentication) { flowID in
                await self.performSilentSignIn(reason: reason, previous: previous, flowID: flowID)
                return .authentication
            }
        }
        silentSignInTask = task
        await task.value
        silentSignInTask = nil
    }

    private func performSilentSignIn(
        reason: SignInProbeReason,
        previous: AuthObservation,
        flowID: UUID
    ) async {
        guard let flowSession = try? await ServiceFlowSession.open(
            id: flowID,
            kind: .authentication,
            service: self,
            actionID: Manifest.SIGN_IN_URL_ACTION_ID,
            args: .object([:]),
            role: .authenticationProbe
        ) else {
            Log.service.info("Service.silentAuth skipped domain=\(domain) reason=\(reason.rawValue) actionPage=false")
            return
        }
        defer { flowSession.close() }
        guard let url = await fetchAuthURL(in: flowSession),
              let host = url.host?.lowercased(),
              ServiceHandoffSession.allowsNavigation(to: url) else {
            Log.service.info("Service.silentAuth skipped domain=\(domain) reason=\(reason.rawValue) authURL=false")
            return
        }
        let session = ServiceAuthSession(service: self, url: url, flowSession: flowSession)
        let attempt = String(session.id.uuidString.prefix(8))
        setAuth(.signingIn(previous: previous))
        Log.service.info("Service.silentAuth start domain=\(domain) attempt=\(attempt) reason=\(reason.rawValue) host=\(host)")
        let outcome = await session.attemptSilently(for: .seconds(1))
        guard outcome == .signedIn else {
            setAuth(.observed(previous))
            Log.service.info("Service.silentAuth done domain=\(domain) attempt=\(attempt) reason=\(reason.rawValue) outcome=\(outcome.rawValue)")
            return
        }
        setAuth(.observed(AuthObservation(value: .signedIn, observedAt: Date())))
        manager.actionScheduler.invalidate(self)
        Log.webView.info("Service.auth pages invalidated domain=\(domain) trigger=silent-sign-in")
        Log.service.info("Service.silentAuth done domain=\(domain) attempt=\(attempt) reason=\(reason.rawValue) outcome=signedIn")
        await manager.logAuthRetention(domain: domain, trigger: "silent-sign-in", outcome: "signedIn")
    }

    func requestAccess(using presenter: (any ServiceAuthPresenting)? = nil, source: AuthSignInSource = .serviceDetail) async throws {
        try await access.request(self) {
            try await self.performAccessRequest(using: presenter, source: source)
        }
    }

    private func performAccessRequest(using presenter: (any ServiceAuthPresenting)?, source: AuthSignInSource) async throws {
        if let iOS = iOSService {
            let current = await iOS.permissionState()
            _ = await iOS.updatePermission(from: current)
            setAuth(await iOS.checkAccess())
            return
        }
        if let mcp = remoteMCPService {
            await checkAccess(policy: .current, reason: .modelSignIn)
            if source != .serviceDetail, signInState.isAuthenticated { return }
            let descriptor = try await mcp.authorize()
            applyResolvedDefinition(ServiceDefinition(mcp: descriptor, metadata: definition), reason: .serviceDetail)
            return
        }
        await checkAccess(policy: .current, reason: .modelSignIn)
        guard !Task.isCancelled, !signInState.isAuthenticated, auth != .notRequired else { return }
        await attemptSilentSignIn(reason: .modelSignIn)
        guard !signInState.isAuthenticated else { return }

        guard supportsWebAuthentication else {
            setAuth(.notRequired)
            return
        }
        guard let presenter else { throw InvokeError.requiresAuth(domain) }
        let previousAuth = auth
        let previous = auth.observation
        setAuth(.signingIn(previous: previous))
        let outcome = await manager.sessionCoordinator.run(for: self, kind: .authentication) { [weak self] flowID in
            guard let self else { return .cancelled }
            await self.performInteractiveSignIn(using: presenter, source: source, flowID: flowID)
            return .authentication
        }
        if case .cancelled = outcome, auth == .signingIn(previous: previous) {
            setAuth(previousAuth)
        }
    }

    private func performInteractiveSignIn(
        using presenter: any ServiceAuthPresenting,
        source: AuthSignInSource,
        flowID: UUID
    ) async {
        let started = Date()
        Log.service.info("Service.signIn requested domain=\(domain) source=\(source.rawValue) auth=\(auth.logLabel)")
        attemptedSilentSignIn = true
        let previous = auth.observation
        guard let flowSession = try? await ServiceFlowSession.open(
            id: flowID,
            kind: .authentication,
            service: self,
            actionID: Manifest.SIGN_IN_URL_ACTION_ID,
            args: .object([:]),
            role: .authenticationProbe
        ) else {
            setAuth(previous.map(Auth.observed) ?? .unavailable(previous: nil, error: "authentication page unavailable"))
            Log.service.error("Service.signIn action page unavailable domain=\(domain) source=\(source.rawValue)")
            return
        }
        defer { flowSession.close() }
        guard let url = await fetchAuthURL(in: flowSession),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let authHost = url.host?.lowercased(),
              ServiceHandoffSession.allowsNavigation(to: url) else {
            setAuth(previous.map(Auth.observed) ?? .unavailable(previous: nil, error: "authentication URL unavailable"))
            Log.service.error("Service.signIn invalid auth URL domain=\(domain) source=\(source.rawValue) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return
        }
        let authSession = ServiceAuthSession(service: self, url: url, flowSession: flowSession)
        let attempt = String(authSession.id.uuidString.prefix(8))
        Log.service.info("Service.signIn presenting domain=\(domain) source=\(source.rawValue) attempt=\(attempt) host=\(authHost)")
        let outcome = await authSession.present(using: presenter)
        let next = outcome == .signedIn
            ? Auth.observed(AuthObservation(value: .signedIn, observedAt: Date()))
            : previous.map(Auth.observed) ?? .observed(AuthObservation(value: .signedOut, observedAt: Date()))
        setAuth(next)
        if outcome == .signedIn {
            manager.actionScheduler.invalidate(self)
            Log.webView.info("Service.auth pages invalidated domain=\(domain) trigger=interactive-sign-in")
        }
        Log.service.info("Service.signIn done domain=\(domain) source=\(source.rawValue) attempt=\(attempt) outcome=\(outcome.rawValue) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        await manager.logAuthRetention(domain: domain, trigger: "interactive-sign-in", outcome: outcome.rawValue)
    }

    func signOut() async {
        let started = Date()
        attemptedSilentSignIn = true
        Log.service.info("Service.signOut start domain=\(domain) auth=\(auth.logLabel)")
        await manager.clearWebsiteData(domain: domain)
        setAuth(.observed(AuthObservation(value: .signedOut, observedAt: Date())))
        Log.service.info("Service.signOut done domain=\(domain) auth=\(auth.logLabel) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        await manager.logAuthRetention(domain: domain, trigger: "sign-out", outcome: "signedOut")
    }

    func clearWebData() async {
        let started = Date()
        attemptedSilentSignIn = true
        Log.service.info("Service.clearWebData start domain=\(domain) auth=\(auth.logLabel)")
        await manager.clearWebsiteData(domain: domain)
        await checkAccess(policy: .current, reason: .clearWebsiteData)
        Log.service.info("Service.clearWebData done domain=\(domain) auth=\(auth.logLabel) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }
}

@MainActor
final class ServiceAccess {
    private static let maxAge: TimeInterval = 30 * 60
    private(set) var signInPreflight: UUID?
    private var checkedAt: Date?
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var requestTask: Task<Void, Error>?

    func request(_ service: Service, operation: @escaping @MainActor () async throws -> Void) async throws {
        if let requestTask { return try await requestTask.value }
        let task = Task { @MainActor in
            do {
                try await operation()
            } catch {
                Log.service.warning("Service.access request failed domain=\(service.domain) error=\(LogPrivacy.text(error.localizedDescription))")
                throw error
            }
        }
        requestTask = task
        defer { requestTask = nil }
        try await task.value
    }

    func didUpdate(_ auth: Service.Auth) {
        revision = UUID()
        signInPreflight = nil
        switch auth {
        case .observed(let observation): checkedAt = observation.observedAt
        case .authorized, .notRequired: checkedAt = Date()
        default: break
        }
    }

    func check(_ service: Service, policy: Service.AccessPolicy, reason: Service.SignInProbeReason, preflight: UUID? = nil, read: @escaping @MainActor () async throws -> Service.Auth) async -> Service.SignInState {
        guard !Task.isCancelled else { return service.signInState }
        if let preflight, preflight == signInPreflight, isFresh(service.auth) {
            signInPreflight = nil
            Log.service.info("Service.access preflight domain=\(service.domain) reason=\(reason.rawValue)")
            return service.signInState
        }
        if service.auth.isSigningIn {
            let previousCheck = checkedAt
            do {
                try await service.awaitAuthenticationAvailability(name: "checkAccess:\(reason.rawValue)")
            } catch {
                return service.signInState
            }
            return await check(service, policy: checkedAt != previousCheck ? .cached : policy, reason: reason, read: read)
        }
        if let task {
            Log.service.info("Service.access joined domain=\(service.domain) reason=\(reason.rawValue)")
            await task.value
            preparePreflight(service, policy: policy, reason: reason)
            return service.signInState
        }
        let local = service.isIOSService
        if !local, policy == .cached, isFresh(service.auth) {
            Log.service.info("Service.access cached domain=\(service.domain) reason=\(reason.rawValue) auth=\(service.auth.logLabel)")
            return service.signInState
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
            if service.webService != nil {
                await service.manager.logAuthRetention(domain: service.domain, trigger: "probe", outcome: next.logLabel)
            }
        }
        self.task = task
        await task.value
        self.task = nil
        preparePreflight(service, policy: policy, reason: reason)
        Log.service.info("Service.access done domain=\(service.domain) reason=\(reason.rawValue) auth=\(service.auth.logLabel) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return service.signInState
    }

    private func preparePreflight(_ service: Service, policy: Service.AccessPolicy, reason: Service.SignInProbeReason) {
        if policy == .current, reason == .modelSignIn, isFresh(service.auth), !Task.isCancelled {
            signInPreflight = revision
        }
    }

    private func isFresh(_ auth: Service.Auth) -> Bool {
        switch auth {
        case .observed, .authorized, .notRequired:
            return checkedAt.map { Date().timeIntervalSince($0) < Self.maxAge } ?? false
        default:
            return false
        }
    }
}

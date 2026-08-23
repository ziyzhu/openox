import Foundation

extension Service {
    private static let signInStateMaxAge: TimeInterval = 30 * 60

    var supportsAuthentication: Bool {
        isMCPService || supportsWebAuthentication
    }

    private var supportsWebAuthentication: Bool {
        definition.action(Manifest.SIGN_IN_STATE_ACTION_ID, includingStandard: true) != nil
    }

    @discardableResult
    func resolveAccess(reason: SignInProbeReason) async -> SignInState {
        if let iOS = iOSService {
            guard let state = await iOS.permissionState() else {
                setAuth(.notRequired)
                return signInState
            }
            switch state {
            case .granted: setAuth(.authorized)
            case .denied: setAuth(.notAuthorized)
            case .notDetermined: setAuth(.authorizationRequired)
            }
            return signInState
        }
        if isMCPService {
            _ = await loadManifest(reason: capabilityReason(for: reason))
            return signInState
        }
        return await resolveSignInState(reason: reason)
    }

    func requestAccess() async throws {
        if let iOS = iOSService {
            let current = await iOS.permissionState()
            let next = await iOS.updatePermission(from: current)
            switch next {
            case .granted: setAuth(.authorized)
            case .denied: setAuth(.notAuthorized)
            case .notDetermined: setAuth(.authorizationRequired)
            case nil: setAuth(.notRequired)
            }
            return
        }
        guard let mcp = remoteMCPService else { return }
        let descriptor = try await mcp.authorize()
        let resolved = ServiceDefinition(mcp: descriptor, metadata: definition)
        applyResolvedDefinition(resolved, reason: .serviceDetail)
    }

    var accessActionLabel: String {
        auth == .authorizationRequired ? "Set Up" : "Manage"
    }

    private func capabilityReason(for reason: SignInProbeReason) -> CapabilityReason {
        switch reason {
        case .serviceDetail: .serviceDetail
        case .attach, .chatOpen: .attach
        case .debug: .debug
        case .modelSignIn, .requireAuth, .clearWebsiteData: .invoke
        }
    }

    private func beginAuthCheck() -> Bool {
        guard !auth.isSigningIn else { return false }
        setAuth(.checking(previous: auth.observation))
        return true
    }

    @discardableResult
    func resolveSignInState(reason: SignInProbeReason) async -> SignInState {
        if case .observed(let observation) = auth,
           Date().timeIntervalSince(observation.observedAt) < Self.signInStateMaxAge {
            Log.service.info("Service.resolveSignInState cached domain=\(domain) reason=\(reason.rawValue) auth=\(auth.logLabel)")
            return signInState
        }
        return await refreshSignInState(reason: reason)
    }

    @discardableResult
    func refreshSignInState(reason: SignInProbeReason) async -> SignInState {
        if isMCPService { return signInState }
        guard supportsWebAuthentication else {
            setAuth(.notRequired)
            return signInState
        }
        if let authProbeTask {
            Log.service.info("Service.refreshSignInState joined domain=\(domain) reason=\(reason.rawValue)")
            await authProbeTask.value
            return signInState
        }
        if auth.isSigningIn {
            do {
                try await awaitAuthenticationAvailability(name: "refreshSignInState:\(reason.rawValue)")
            } catch {
                return signInState
            }
            return await refreshSignInState(reason: reason)
        }
        guard beginAuthCheck() else {
            if let authProbeTask { await authProbeTask.value }
            return signInState
        }
        let previous = auth.observation
        let id = String(UUID().uuidString.prefix(8))
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runGetSignInStateProbe(id: id, reason: reason, previous: previous)
        }
        authProbeTask = task
        let started = Date()
        Log.service.info("Service.refreshSignInState start domain=\(domain) id=\(id) reason=\(reason.rawValue) previous=\(previous?.value.rawValue ?? "unknown")")
        await task.value
        authProbeTask = nil
        let status = Task.isCancelled ? "canceled" : "complete"
        Log.service.info("Service.refreshSignInState done domain=\(domain) id=\(id) reason=\(reason.rawValue) status=\(status) auth=\(auth.logLabel) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return signInState
    }

    private func runGetSignInStateProbe(id: String, reason: SignInProbeReason, previous: AuthObservation?) async {
        let result = await Manifest.getSignInState(service: self)
        Log.service.info("Service.runGetSignInStateProbe result domain=\(domain) id=\(id) reason=\(reason.rawValue) outcome=\(result.outcome.logLabel)")
        guard !Task.isCancelled else {
            setAuth(previous.map(Auth.observed) ?? .unknown)
            Log.service.info("Service.runGetSignInStateProbe canceled domain=\(domain) id=\(id) reason=\(reason.rawValue)")
            return
        }
        switch result.outcome {
        case .signedIn:
            setAuth(.observed(AuthObservation(value: .signedIn, observedAt: result.at)))
        case .signedOut:
            setAuth(.observed(AuthObservation(value: .signedOut, observedAt: result.at)))
        case .error(let error):
            setAuth(.unavailable(previous: previous, error: error))
            Log.service.warning("Service.runGetSignInStateProbe unavailable domain=\(domain) id=\(id) reason=\(reason.rawValue) previous=\(previous?.value.rawValue ?? "unknown") error=\(LogPrivacy.text(error))")
        }
        await manager.logAuthRetention(domain: domain, trigger: "probe", outcome: result.outcome.logLabel)
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
        guard case .observed(let previous) = auth,
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

    func signIn(using presenter: any ServiceAuthPresenting, source: AuthSignInSource) async {
        if isMCPService {
            guard signInState != .authorized else { return }
            let previous = auth
            do {
                try await authorizeMCP()
            } catch {
                setAuth(previous)
                Log.service.error("RemoteMCP.authorize failed id=\(domain) source=\(source.rawValue) error=\(error.localizedDescription)")
            }
            return
        }
        guard supportsWebAuthentication else {
            setAuth(.notRequired)
            return
        }
        var previousAuth = auth
        var previous = auth.observation
        setAuth(.signingIn(previous: previous))
        if let silentSignInTask {
            Log.service.info("Service.signIn joined silent domain=\(domain) source=\(source.rawValue)")
            await silentSignInTask.value
            if auth.isSignedIn { return }
            previousAuth = auth
            previous = auth.observation ?? previous
            setAuth(.signingIn(previous: previous))
        }
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

    func authorizeMCP() async throws {
        try await requestAccess()
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
        await refreshSignInState(reason: .clearWebsiteData)
        Log.service.info("Service.clearWebData done domain=\(domain) auth=\(auth.logLabel) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }
}

import Foundation
import WebKit

extension ServiceOperations {
    private static let loginStepLimit = 5

    func completeLogin(service: Service, secrets: SecretAttempt?, input: JSONValue, session: JSONValue?, pageURL: String?,
                       approve: @escaping @MainActor (String, Any?) async -> Bool) async throws -> JSONValue {
        var page = loginPage(service)
        if let secrets {
            guard let action = await service.resolvedAction(WebSessionContract.loginAction, args: input, pageURL: pageURL, scopeID: native.id) else {
                throw Service.EvalError.notReady
            }
            let opened = try await service.openSessionPage(for: action)
            page = try await serviceManager.actionScheduler.schedule(action, on: opened, destination: action.baseURL) { $0 }
            let verified = await completeAutomaticLogin(service: service, secrets: secrets, input: input, page: opened, approve: approve)
            secrets.releaseRendering()
            if verified { return Self.loginResult(interaction: "automatic", verified: true) }
            if secrets.denied {
                throw OxFunctionError(code: "permission_denied", message: "\(service.title) login: the user did not allow this action to use the saved login.", recovery: "Stop. Do not retry with the same login unless the user asks; offer manual login instead.")
            }
        }
        try Task.checkCancellation()
        let preparedPage = page
        return try await native.handoff(title: String(localized: "Sign in to \(service.title)")) { [self] in
            try await handOffLogin(service: service, secrets: secrets, input: input, session: session, pageURL: pageURL,
                                   prepare: secrets != nil, rememberFor: redirectProvider(for: service, in: preparedPage),
                                   page: preparedPage, approve: approve)
        }
    }

    func redirectProvider(for service: Service, in page: BrowserSession? = nil) -> Service? {
        guard let page = page ?? loginPage(service), page.scopeID == native.id,
              let host = page.page.url?.host, let provider = webLoginService(containing: host),
              provider !== service else { return nil }
        return provider
    }

    private func webLoginService(containing host: String) -> Service? {
        serviceManager.services.filter {
            $0.isWebService && WebSessionContract.isEnabled($0.definition)
                && SecretAttempt.host(host, isWithin: $0.definition.actionNamespace)
        }.max { $0.domain.count < $1.domain.count }
    }

    private func completeAutomaticLogin(service: Service, secrets: SecretAttempt, input: JSONValue, page: BrowserSession,
                                        approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        guard !secrets.isCoolingDown else {
            Log.service.info("Service.login automatic skipped domain=\(service.domain) reason=cooldown")
            return false
        }
        secrets.keepRendering(page)
        var verified = await runLoginSteps(service: service, secrets: secrets, input: input, page: page, approve: approve)
        if !verified, !secrets.denied, let provider = redirectProvider(for: service, in: page),
           secrets.owners.contains(provider.definition.actionNamespace) {
            Log.service.info("Service.login hop domain=\(service.domain) provider=\(provider.domain) page=\(page.logLabel)")
            _ = await runLoginSteps(service: provider, secrets: secrets, input: input, page: page, approve: approve)
            if !secrets.denied, page.page.url?.host.map(service.isServiceHost) == true,
               redirectProvider(for: service, in: page) == nil {
                verified = await settledSession(service: service, secrets: secrets, page: page, approve: approve)
            }
        }
        if verified { secrets.recordSuccess() }
        else if secrets.stepEnd == .stalled { secrets.recordRejection() }
        Log.service.info("Service.login automatic domain=\(service.domain) verified=\(verified) end=\(secrets.stepEnd.rawValue) retrievals=\(secrets.retrievals)")
        return verified
    }

    private func runLoginSteps(service: Service, secrets: SecretAttempt, input: JSONValue, page: BrowserSession,
                               approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        secrets.stepEnd = .running
        for step in 1...Self.loginStepLimit {
            guard !Task.isCancelled, page.page.url?.host.map(service.isServiceHost) == true,
                  redirectProvider(for: service, in: page) == nil else {
                secrets.stepEnd = .leftSite
                break
            }
            guard let before = await loginState(page) else {
                secrets.stepEnd = .awaitingPerson
                break
            }
            let retrievals = secrets.retrievals
            guard await runLoginStep(service: service, secrets: secrets, input: input, pageURL: nil, in: page,
                                     approve: approve) else {
                secrets.stepEnd = .finished
                break
            }
            try? await Task.sleep(for: .milliseconds(1500))
            await settle(page)
            guard page.page.url?.host.map(service.isServiceHost) == true,
                  redirectProvider(for: service, in: page) == nil else {
                secrets.stepEnd = .leftSite
                break
            }
            guard let after = await loginState(page), before != after else {
                secrets.stepEnd = secrets.retrievals > retrievals ? .stalled : .awaitingPerson
                Log.service.info("Service.login step stopped domain=\(service.domain) step=\(step) reason=unchanged-or-unavailable retrievals=\(secrets.retrievals)")
                break
            }
            Log.service.info("Service.login step domain=\(service.domain) step=\(step) retrievals=\(secrets.retrievals) page=\(page.logLabel)")
        }
        if secrets.stepEnd == .running { secrets.stepEnd = .finished }
        if secrets.denied || Task.isCancelled { return false }
        if secrets.stepEnd == .leftSite { return false }
        return await settledSession(service: service, secrets: secrets, page: page, approve: approve)
    }

    private func loginState(_ page: BrowserSession) async -> String? {
        let source = """
        const controls = [];
        let inspected = 0;
        const visit = root => {
            for (const element of root.querySelectorAll('*')) {
                if (++inspected > 2048 || controls.length >= 128) break;
                const style = getComputedStyle(element);
                if (element.hidden || style.display === 'none' || style.visibility === 'hidden') continue;
                if (element.matches('input:not([type=hidden]),button,a,select,iframe,[role=button],[role=alert]')) {
                    let visible = true;
                    for (let parent = element.parentElement; parent; parent = parent.parentElement) {
                        const style = getComputedStyle(parent);
                        if (parent.hidden || style.display === 'none' || style.visibility === 'hidden') { visible = false; break; }
                    }
                    if (visible) controls.push([element.tagName, element.getAttribute('type'), element.getAttribute('autocomplete'),
                        !!element.disabled, !!element.readOnly, element.getAttribute('aria-expanded'), element.getAttribute('aria-busy')]);
                }
                if (element.shadowRoot) visit(element.shadowRoot);
            }
        };
        visit(document);
        return JSON.stringify(controls);
        """
        guard let state = try? await page.evalOnce(page, source, timeout: 2) as? String else { return nil }
        return "\(page.navigationGeneration):\(page.page.url?.absoluteString ?? ""):\(state)"
    }

    private func runLoginStep(service: Service, secrets: SecretAttempt, input: JSONValue, pageURL: String?,
                              in page: BrowserSession?,
                              approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        for _ in 0..<2 {
            let result = await service.invokeAction(WebSessionContract.loginAction, args: input, pageURL: pageURL, in: page,
                                                    secrets: secrets, scopeID: native.id, approve: approve)
            guard !secrets.awaitingApproval.isEmpty else {
                if case .success = result { return true }
                return false
            }
            guard await secrets.authorizePending() else { return false }
            Log.service.info("Service.login step approved domain=\(service.domain)")
        }
        return false
    }

    func handOffLogin(service: Service, secrets: SecretAttempt?, input: JSONValue, session: JSONValue?, pageURL: String?,
                              prepare: Bool, rememberFor destination: Service? = nil, page: BrowserSession? = nil,
                              approve: @escaping @MainActor (String, Any?) async -> Bool) async throws -> JSONValue {
        if prepare, page == nil, loginPage(service)?.page.url?.host.map(service.isServiceHost) != true {
            _ = await service.invokeAction(WebSessionContract.loginAction, args: .object([:]), pageURL: pageURL, scopeID: native.id, approve: approve)
        }
        let capture = try await presentLogin(service: service, input: .object([:]), session: session, pageURL: pageURL, page: page)
        await offerToRemember(capture, service: service, also: destination)
        let trace = capture.trace
        Log.service.info("Service.login trace domain=\(service.domain) steps=\(capture.steps.count) truncated=\(capture.truncated)")
        await capture.discard()
        let verified = await settledSession(service: service, secrets: secrets, page: page, approve: approve)
        return Self.loginResult(interaction: "completed", verified: verified, trace: trace)
    }

    private static func loginResult(interaction: String, verified: Bool, trace: JSONValue? = nil) -> JSONValue {
        var result: [String: JSONValue] = ["interaction": .string(interaction), "authentication": .string(verified ? "verified" : "unverified")]
        if let trace { result["loginTrace"] = trace }
        return .object(result)
    }

    func loginPage(_ service: Service) -> BrowserSession? {
        serviceManager.browserSessions.sessions
            .filter { $0.scopeID == native.id && $0.lastInvocation?.domain == service.domain }
            .filter { $0.lastInvocation?.actionID == WebSessionContract.loginAction }
            .max { ($0.lastInvocation?.startedAt ?? .distantPast) < ($1.lastInvocation?.startedAt ?? .distantPast) }
    }

    private func settle(_ page: BrowserSession) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while page.navigationPhase.load != nil || page.page.isLoading, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func settledSession(service: Service, secrets: SecretAttempt?, page: BrowserSession? = nil,
                                approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        for attempt in 1...3 {
            if let page { await settle(page) }
            if await hasIntendedSession(service: service, secrets: secrets, in: page, approve: approve) { return true }
            guard attempt < 3 else { break }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        return false
    }

    func hasIntendedSession(service: Service, secrets: SecretAttempt?, in page: BrowserSession? = nil,
                            approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        let onSite = page?.page.url?.host.map(service.isServiceHost) == true
        guard case .success(let value) = await service.invokeAction(WebSessionContract.listAction, args: .object([:]),
                                                                     in: onSite ? page : nil, scopeID: native.id, approve: approve),
              let sessions = value.arrayValue, !sessions.isEmpty else { return false }
        guard let secrets, secrets.owners.contains(service.definition.actionNamespace) else { return true }
        let ids = Set(sessions.compactMap { $0.objectValue?["id"]?.stringValue })
        let identities = secrets.accountIdentities
        if !identities.isEmpty {
            guard let matched = identities.first(where: { ids.contains($0.value) }) else { return false }
            Log.service.info("Service.login identity matched domain=\(service.domain) key=\(matched.key)")
            return true
        }
        let names = sessions.flatMap { session in
            ["id", "label"].compactMap { session.objectValue?[$0]?.stringValue?.lowercased() }
        }
        let usernames = secrets.usernames
        guard !usernames.isEmpty, names.contains(where: { $0.contains("@") }) else { return true }
        for session in sessions {
            guard let id = session.objectValue?["id"]?.stringValue else { continue }
            let label = session.objectValue?["label"]?.stringValue?.lowercased() ?? ""
            guard let match = usernames.first(where: { $0.value == id.lowercased() || label.contains($0.value) }) else { continue }
            try? Secret.recordAccountIdentity(key: match.key, identity: id)
            return true
        }
        return false
    }

    private func presentLogin(service: Service, input: JSONValue, session: JSONValue?, pageURL: String?, page: BrowserSession?) async throws -> LoginCapture {
        let actionID = WebSessionContract.loginAction
        guard let action = await service.resolvedAction(actionID, args: input, session: session, pageURL: pageURL, scopeID: native.id),
              let lease = try await serviceManager.actionScheduler.reserveForPresentation(action, on: page ?? loginPage(service), allowUnready: true) else {
            throw OxFunctionError(code: "page_unavailable", message: "Login preparation has no idle live page.", recovery: "Inspect the page and preparation failure before retrying login.")
        }
        defer { lease.release() }
        try await requirePresentablePage(service: service, page: lease.page)
        guard lease.isActive else { throw Service.EvalError.contextInvalidated }
        let handoff = ServiceHandoffSession(
            service: service,
            servicePage: lease.page,
            title: service.title,
            navigationTitle: String(localized: "Log in"),
            control: .login(domain: service.domain, serviceName: service.title)
        )
        Log.service.info("Service.login presenting domain=\(service.domain) page=\(lease.page.logLabel)")
        let capture = LoginCapture()
        await capture.install(on: lease.page, owner: service, credentials: rememberSecret != nil)
        let outcome: ServiceHandoffSession.Outcome
        if let presentServiceHandoff {
            outcome = await presentServiceHandoff(service, lease.page, handoff)
        } else {
            outcome = await native.presentations.serviceHandoff.present(session: handoff)
        }
        await capture.remove()
        try Task.checkCancellation()
        Log.service.info("Service.login interaction domain=\(service.domain) page=\(lease.page.logLabel) outcome=\(outcome.rawValue)")
        if outcome == .cancelled {
            throw OxFunctionError(code: "handoff_incomplete", message: "The user tapped Cancel or closed the login page before finishing sign-in.", recovery: "Tell the user login was not completed. Do not reopen automatically; ask whether they want to try again. The page is preserved.")
        }
        guard outcome == .completed, lease.isActive else {
            throw OxFunctionError(code: "page_unavailable", message: "The login page could not be presented or was closed by the app.", recovery: "Do not reopen automatically. Report the failure and ask the user whether to continue; the page is preserved.")
        }
        if lease.page.page.url?.host.map(service.isServiceHost) != true {
            await settle(lease.page)
            try Task.checkCancellation()
            guard lease.isActive,
                  await service.navigate(action.baseURL, in: lease.page) != nil else {
                throw OxFunctionError(code: "page_unavailable", message: "The login interaction finished, but its target page could not be resumed.", recovery: "Inspect the preserved page. Do not assume authentication succeeded or repeat a mutation.")
            }
        }
        Log.service.info("Service.login acknowledged domain=\(service.domain) page=\(lease.page.logLabel)")
        return capture
    }

    private func offerToRemember(_ capture: LoginCapture, service: Service, also destination: Service?) async {
        guard let rememberSecret else { return }
        guard let captured = capture.credential() else {
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=nothing-captured")
            return
        }
        let owner = webLoginService(containing: captured.owner)?.definition.actionNamespace ?? "web:\(captured.owner)"
        guard !Secret.isNeverRemembered(owner) else {
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=never")
            return
        }
        guard case .success(let sessions) = await service.invokeAction(WebSessionContract.listAction, args: .object([:]), scopeID: native.id) else {
            Log.service.warning("Service.login remember skipped domain=\(service.domain) reason=session-discovery-failed")
            return
        }
        guard let identity = sessions.arrayValue?.first?.objectValue?["id"]?.stringValue, !identity.isEmpty else {
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=no-authenticated-session")
            return
        }
        let consumers = [service, destination].compactMap { $0?.definition.qualifiedActionName(WebSessionContract.loginAction) }
        let existing = (try? Secret.entries())?.first {
            $0.type == .account && $0.serviceID == owner && (try? Secret.fields(key: $0.key))?["username"] == captured.values["username"]
        }
        if let existing, (try? Secret.fields(key: existing.key)) == captured.values {
            consumers.forEach { try? Secret.setAccess(key: existing.key, consumer: $0, policy: .allow) }
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=unchanged")
            return
        }
        let key = existing?.key ?? "login.\(owner.split(separator: ":").last ?? "site").\(UUID().uuidString.prefix(8).lowercased())"
        let spec = SecretEntrySpec(key: key, type: .account, serviceID: owner, prefill: captured.values)
        guard await rememberSecret(spec) else {
            Log.service.info("Service.login remember declined domain=\(service.domain)")
            return
        }
        do {
            for consumer in consumers { try Secret.setAccess(key: key, consumer: consumer, policy: .allow) }
            if owner == service.definition.actionNamespace {
                try Secret.recordAccountIdentity(key: key, identity: identity)
            }
            Log.service.info("Service.login remember saved domain=\(service.domain) owner=\(owner) updated=\(existing != nil)")
        } catch {
            Log.service.error("Service.login remember access error=\(error.localizedDescription)")
        }
    }
}

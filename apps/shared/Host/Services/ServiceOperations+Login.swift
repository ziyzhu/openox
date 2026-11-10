import Foundation
import WebKit

extension ServiceOperations {
    private static let loginStepLimit = 5
    private static let returnLimit = 3

    func completeLogin(service: Service, secrets: SecretAttempt?, input: JSONValue, session: JSONValue?, pageURL: String?,
                       approve: @escaping @MainActor (String, Any?) async -> Bool) async throws -> JSONValue {
        if let secrets {
            let verified = await completeAutomaticLogin(service: service, secrets: secrets, input: input, pageURL: pageURL, approve: approve)
            secrets.releaseRendering()
            if verified { return Self.loginResult(interaction: "automatic", verified: true) }
            if secrets.denied {
                throw OxFunctionError(code: "permission_denied", message: "\(service.title) login: the user did not allow this action to use the saved login.", recovery: "Stop. Do not retry with the same login unless the user asks; offer manual login instead.")
            }
        }
        if let provider = loginProvider(for: service, secrets: secrets) {
            return try await completeProviderChain(service: service, provider: provider, secrets: secrets, input: input,
                                                   session: session, pageURL: pageURL, approve: approve)
        }
        return try await handOffLogin(service: service, secrets: secrets, input: input, session: session, pageURL: pageURL,
                                      prepare: secrets != nil, approve: approve)
    }

    func redirectProvider(for service: Service) -> Service? {
        for page in service.servicePages {
            guard let host = page.page.url?.host, !service.isServiceHost(host) else { continue }
            if let provider = webLoginService(containing: host) { return provider }
        }
        return nil
    }

    private func loginProvider(for service: Service, secrets: SecretAttempt?) -> Service? {
        let destination = service.definition.actionNamespace
        if let owner = secrets?.owners.first(where: { $0 != destination }) {
            return serviceManager.services.first { $0.isWebService && $0.definition.actionNamespace == owner }
                .flatMap { WebSessionContract.isEnabled($0.definition) ? $0 : nil }
        }
        return redirectProvider(for: service)
    }

    private func webLoginService(containing host: String) -> Service? {
        serviceManager.services.first {
            $0.isWebService && WebSessionContract.isEnabled($0.definition)
                && SecretAttempt.host(host, isWithin: $0.definition.actionNamespace)
        }
    }

    private func completeAutomaticLogin(service: Service, secrets: SecretAttempt, input: JSONValue, pageURL: String?,
                                        approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        guard !secrets.isCoolingDown else {
            Log.service.info("Service.login automatic skipped domain=\(service.domain) reason=cooldown")
            return false
        }
        let provider = loginProvider(for: service, secrets: secrets).flatMap { secrets.owners.contains($0.definition.actionNamespace) ? $0 : nil }
        var verified: Bool
        if let provider {
            Log.service.info("Service.login hop domain=\(service.domain) provider=\(provider.domain)")
            verified = await settledSession(service: provider, secrets: secrets, approve: approve)
            if !verified {
                verified = await runLoginSteps(service: provider, secrets: secrets, input: input, pageURL: nil,
                                               approve: approve, started: false)
            }
            if verified {
                verified = await returnToDestination(service: service, secrets: secrets, input: input, pageURL: pageURL, approve: approve)
            }
        } else {
            verified = await runLoginSteps(service: service, secrets: secrets, input: input, pageURL: pageURL,
                                           approve: approve, started: false)
        }
        if verified { secrets.recordSuccess() }
        else if secrets.stepEnd == .stalled { secrets.recordRejection() }
        Log.service.info("Service.login automatic domain=\(service.domain) verified=\(verified) end=\(secrets.stepEnd.rawValue) retrievals=\(secrets.retrievals)")
        return verified
    }

    private func runLoginSteps(service: Service, secrets: SecretAttempt, input: JSONValue, pageURL: String?,
                               approve: @escaping @MainActor (String, Any?) async -> Bool, started: Bool) async -> Bool {
        secrets.stepEnd = .running
        if !started {
            guard await runLoginStep(service: service, secrets: secrets, input: input, pageURL: pageURL, in: nil,
                                     approve: approve) else { return false }
        }
        var observed = 0
        var previousURL: URL?
        for step in 2...Self.loginStepLimit {
            guard secrets.retrievals > observed, let page = loginPage(service) else {
                secrets.stepEnd = secrets.retrievals > 0 ? .awaitingPerson : .finished
                break
            }
            observed = secrets.retrievals
            try? await Task.sleep(for: .milliseconds(1500))
            await settle(page)
            guard let url = page.page.url, let host = url.host, service.isServiceHost(host) else {
                secrets.stepEnd = .leftSite
                break
            }
            guard url != previousURL else {
                secrets.stepEnd = .stalled
                Log.service.info("Service.login step stalled domain=\(service.domain) step=\(step) path=\(url.path)")
                break
            }
            previousURL = url
            guard await runLoginStep(service: service, secrets: secrets, input: input, pageURL: nil, in: page,
                                     approve: approve) else {
                secrets.stepEnd = .finished
                break
            }
            Log.service.info("Service.login step domain=\(service.domain) step=\(step) retrievals=\(secrets.retrievals) path=\(page.page.url?.path ?? "?")")
        }
        if secrets.stepEnd == .running { secrets.stepEnd = .finished }
        guard secrets.retrievals > 0 else {
            return await hasIntendedSession(service: service, secrets: secrets, in: loginPage(service), approve: approve)
        }
        return await settledSession(service: service, secrets: secrets, page: loginPage(service), approve: approve)
    }

    private func runLoginStep(service: Service, secrets: SecretAttempt, input: JSONValue, pageURL: String?,
                              in page: Service.ServiceWebPage?,
                              approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        for _ in 0..<2 {
            let result = await service.invokeAction(WebSessionContract.loginAction, args: input, pageURL: pageURL, in: page,
                                                    secrets: secrets, approve: approve)
            guard !secrets.awaitingApproval.isEmpty else {
                if case .success = result { return true }
                return false
            }
            guard await secrets.authorizePending() else { return false }
            Log.service.info("Service.login step approved domain=\(service.domain)")
        }
        return false
    }

    private func returnToDestination(service: Service, secrets: SecretAttempt?, input: JSONValue, pageURL: String?,
                                     approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        if await settledSession(service: service, secrets: secrets, approve: approve) { return true }
        for attempt in 1...Self.returnLimit {
            guard case .success = await service.invokeAction(WebSessionContract.loginAction, args: input, pageURL: pageURL,
                                                              secrets: secrets, approve: approve) else { continue }
            if await settledSession(service: service, secrets: secrets, page: loginPage(service), approve: approve) {
                Log.service.info("Service.login returned domain=\(service.domain) attempts=\(attempt)")
                return true
            }
        }
        return false
    }

    private func completeProviderChain(service: Service, provider: Service, secrets: SecretAttempt?, input: JSONValue,
                                       session: JSONValue?, pageURL: String?,
                                       approve: @escaping @MainActor (String, Any?) async -> Bool) async throws -> JSONValue {
        Log.service.info("Service.login chain domain=\(service.domain) provider=\(provider.domain)")
        var providerTrace: JSONValue?
        if !(await settledSession(service: provider, secrets: secrets, approve: approve)) {
            let result = try await handOffLogin(service: provider, secrets: secrets, input: .object([:]), session: nil, pageURL: nil,
                                               prepare: true, rememberFor: service, approve: approve)
            providerTrace = result.objectValue?["loginTrace"]
            guard await settledSession(service: provider, secrets: secrets, approve: approve) else {
                throw OxFunctionError(code: "handoff_incomplete", message: "Sign-in to \(provider.title) did not complete, so \(service.title) is still not signed in.", recovery: "Tell the user sign-in was not completed. Do not reopen it automatically; ask whether they want to try again.")
            }
        }
        if await returnToDestination(service: service, secrets: secrets, input: input, pageURL: pageURL, approve: approve) {
            return Self.loginResult(interaction: "completed", verified: true, trace: providerTrace)
        }
        let result = try await handOffLogin(service: service, secrets: secrets, input: input, session: session, pageURL: pageURL,
                                           prepare: true, approve: approve)
        guard let providerTrace else { return result }
        let destinationTrace = result.objectValue?["loginTrace"]?.objectValue
        let steps = (providerTrace.objectValue?["steps"]?.arrayValue ?? []) + (destinationTrace?["steps"]?.arrayValue ?? [])
        return result.merging(["loginTrace": .object([
            "steps": .array(steps),
            "truncated": .bool(providerTrace.objectValue?["truncated"]?.boolValue == true || destinationTrace?["truncated"]?.boolValue == true)
        ])])
    }

    private func handOffLogin(service: Service, secrets: SecretAttempt?, input: JSONValue, session: JSONValue?, pageURL: String?,
                              prepare: Bool, rememberFor destination: Service? = nil,
                              approve: @escaping @MainActor (String, Any?) async -> Bool) async throws -> JSONValue {
        if prepare, loginPage(service)?.page.url?.host.map(service.isServiceHost) != true {
            _ = await service.invokeAction(WebSessionContract.loginAction, args: .object([:]), pageURL: pageURL, approve: approve)
        }
        let capture = try await presentLogin(service: service, input: .object([:]), session: session, pageURL: pageURL)
        await offerToRemember(capture, service: service, also: destination)
        let trace = capture.trace
        Log.service.info("Service.login trace domain=\(service.domain) steps=\(capture.steps.count) truncated=\(capture.truncated)")
        await capture.discard()
        let verified = await settledSession(service: service, secrets: secrets, approve: approve)
        return Self.loginResult(interaction: "completed", verified: verified, trace: trace)
    }

    private static func loginResult(interaction: String, verified: Bool, trace: JSONValue? = nil) -> JSONValue {
        var result: [String: JSONValue] = ["interaction": .string(interaction), "authentication": .string(verified ? "verified" : "unverified")]
        if let trace { result["loginTrace"] = trace }
        return .object(result)
    }

    func loginPage(_ service: Service) -> Service.ServiceWebPage? {
        service.servicePages
            .filter { $0.lastInvocation?.actionID == WebSessionContract.loginAction }
            .max { ($0.lastInvocation?.startedAt ?? .distantPast) < ($1.lastInvocation?.startedAt ?? .distantPast) }
    }

    private func settle(_ page: Service.ServiceWebPage) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while page.navigationPhase.load != nil || page.page.isLoading, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func settledSession(service: Service, secrets: SecretAttempt?, page: Service.ServiceWebPage? = nil,
                                approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        for attempt in 1...3 {
            if let page { await settle(page) }
            if await hasIntendedSession(service: service, secrets: secrets, in: page, approve: approve) { return true }
            guard attempt < 3 else { break }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        return false
    }

    func hasIntendedSession(service: Service, secrets: SecretAttempt?, in page: Service.ServiceWebPage? = nil,
                            approve: @escaping @MainActor (String, Any?) async -> Bool) async -> Bool {
        let onSite = page?.page.url?.host.map(service.isServiceHost) == true
        guard case .success(let value) = await service.invokeAction(WebSessionContract.listAction, args: .object([:]),
                                                                     in: onSite ? page : nil, approve: approve),
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

    private func presentLogin(service: Service, input: JSONValue, session: JSONValue?, pageURL: String?) async throws -> LoginCapture {
        let actionID = WebSessionContract.loginAction
        guard let action = await service.resolvedAction(actionID, args: input, session: session, pageURL: pageURL),
              let lease = try await serviceManager.actionScheduler.reserveForPresentation(action, allowUnready: true) else {
            throw OxFunctionError(code: "page_unavailable", message: "Login preparation has no idle live page.", recovery: "Inspect the page and preparation failure before retrying login.")
        }
        defer { lease.release() }
        try await requirePresentablePage(service: service, page: lease.page)
        guard lease.isActive else { throw Service.EvalError.contextInvalidated }
        let handoff = ServiceHandoffSession(
            service: service,
            servicePage: lease.page,
            title: service.title,
            navigationTitle: String(localized: "Log in")
        )
        Log.service.info("Service.login presenting domain=\(service.domain) page=\(lease.page.logLabel)")
        let capture = LoginCapture()
        await capture.install(on: lease.page, credentials: rememberSecret != nil)
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
        guard let rememberSecret,
              case .success(let sessions) = await service.invokeAction(WebSessionContract.listAction, args: .object([:])),
              let account = sessions.arrayValue?.first?.objectValue else { return }
        let fallback = account["label"]?.stringValue ?? account["id"]?.stringValue
        guard let captured = capture.credential(fallbackUsername: fallback) else {
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=nothing-captured")
            return
        }
        let owner = webLoginService(containing: captured.owner)?.definition.actionNamespace ?? "web:\(captured.owner)"
        guard !Secret.isNeverRemembered(owner) else {
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=never")
            return
        }
        let consumers = [service, destination].compactMap { $0?.definition.qualifiedActionName(WebSessionContract.loginAction) }
        let existing = (try? Secret.entries())?.first {
            $0.type == .account && $0.serviceID == owner && (try? Secret.fields(key: $0.key))?["username"] == captured.values["username"]
        }
        if let existing, (try? Secret.fields(key: existing.key)) == captured.values {
            consumers.forEach { try? Secret.setAccess(key: existing.key, consumer: $0, policy: .allow) }
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
            if owner == service.definition.actionNamespace, let identity = account["id"]?.stringValue {
                try Secret.recordAccountIdentity(key: key, identity: identity)
            }
            Log.service.info("Service.login remember saved domain=\(service.domain) owner=\(owner) updated=\(existing != nil)")
        } catch {
            Log.service.error("Service.login remember access error=\(error.localizedDescription)")
        }
    }
}

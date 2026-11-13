import Foundation
import WebKit

extension Service {
    func invokeAction(
        _ actionId: String,
        args: JSONValue,
        role: InvocationRole = .standard,
        session requestedSession: JSONValue? = nil,
        pageURL: String? = nil,
        in ownedPage: BrowserSession? = nil,
        secrets: SecretAttempt? = nil,
        scopeID: UUID? = nil,
        approve: (@MainActor (_ action: String, _ args: Any?) async -> Bool)? = nil
    ) async -> Result<JSONValue, Error> {
        let name = "\(domain):\(actionId)"
        guard hasWebRuntime else { return .failure(InvokeError.unknown(name)) }
        do { try await manager.requireInvocationAccess(for: self) }
        catch { return .failure(error) }
        let invocationID = UUID()
        let invocation = String(invocationID.uuidString.prefix(8))
        let started = Date()
        func elapsedMs() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        await loadManifest()
        guard let action = definition.action(actionId, includingStandard: true) else {
            return .failure(InvokeError.unknown(name))
        }
        guard let inputSchema = definition.inputSchema(for: action), let outputSchema = action.outputSchema else {
            return .failure(InvokeError.invalidContract(name))
        }
        let definitions = definition.definitions
        let inputViolations = JSONSchemaValidator.validate(args, against: inputSchema, definitions: definitions,
                                                           allowingSecretReferences: secrets != nil)
        if !inputViolations.isEmpty {
            Log.service.error("Service.invoke invalid-input name=\(name) violations=\(InvokeError.describe(inputViolations))")
            return .failure(InvokeError.invalidInput(name, inputViolations))
        }
        guard let actionBaseURL = action.resolvedBaseURL(for: args),
              let scripts = resolutionState.resolved?.actions else {
            return .failure(InvokeError.invalidContract(name))
        }
        do {
            _ = try executionURL(defaultURL: actionBaseURL, session: requestedSession, pageURL: pageURL)
        } catch { return .failure(error) }
        func approveInvocation(_ id: String, input: JSONValue) async -> Bool {
            let qualifiedName = definition.qualifiedActionName(id)
            if let approve { return await approve(qualifiedName, input.toAny()) }
            if WebSessionContract.isEnabled(definition),
               id == WebSessionContract.listAction || id == WebSessionContract.loginAction {
                return manager.actionPolicy(for: qualifiedName, default: .allow) == .allow
            }
            return true
        }
        if actionId != WebConversationContract.actionID || WebConversationContract.requiresApproval(args) {
            let allow = await approveInvocation(actionId, input: args)
            Log.service.info("Service.invoke approval name=\(name) allow=\(allow)")
            if !allow { return .failure(InvokeError.denied(name)) }
        }
        do {
            try await awaitAuthenticationAvailability(name: name)
        } catch {
            return .failure(error)
        }
        do { try await manager.requireInvocationAccess(for: self) }
        catch { return .failure(error) }
        if actionId == WebConversationContract.actionID, ownedPage == nil {
            do { return .success(try await manager.invokeConversation(service: self, args: args, owner: .client, session: requestedSession, pageURL: pageURL, approve: approve)) }
            catch { return .failure(error) }
        }
        let targetPage = ownedPage ?? scopeID.flatMap { scope in
            pageURL == nil ? manager.browserSessions.reusablePage(for: self, scopeID: scope) : nil
        }
        let selectedSession: JSONValue?
        let destination: URL
        do {
            if targetPage == nil {
                selectedSession = try await invocationSession(action: action, session: requestedSession, pageURL: pageURL, scopeID: scopeID, approve: approve)
            } else {
                selectedSession = try await invocationSession(action: action, session: requestedSession, pageURL: pageURL,
                                                              in: targetPage, scopeID: scopeID, approve: approve)
            }
            destination = try executionURL(defaultURL: actionBaseURL, session: selectedSession, pageURL: pageURL)
            Log.service.info("Service.invoke routing id=\(invocation) name=\(name) source=\(pageURL == nil ? "manifest" : "pageUrl") selectedSession=\(selectedSession != nil) destination=\(LogPrivacy.url(destination.absoluteString))")
            try Task.checkCancellation()
        } catch { return .failure(error) }
        let pageAction = Action(
            service: self,
            definition: action,
            baseURL: destination,
            role: role == .standard ? .blockingAction : role,
            scripts: scripts,
            session: selectedSession,
            scopeID: scopeID
        )
        let argsJSON = (try? JSONEncoder().encode(args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let idJSON = (try? JSONEncoder().encode(actionId))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let source = "return await window.ox.callServiceAction(\(idJSON), \(argsJSON));"

        func evaluate(in session: BrowserSession, startingNavigation: Int) async -> Result<JSONValue, Error> {
            defer {
                if session.secretAttempt === secrets {
                    session.secretAttempt = nil
                    session.frameSecretContext = nil
                    SecretRequestGuard.remove(from: session)
                }
            }
            guard owns(session), session.navigationGeneration == startingNavigation else {
                Log.service.error("Service.invoke stale-admission id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration) state=\(resolutionState.logLabel)")
                return .failure(EvalError.contextInvalidated)
            }
            guard let host = session.page.url?.host, isServiceHost(host) else {
                let offHost = session.page.url?.host ?? "?"
                if auth.isLoggingIn {
                    Log.service.info("Service.invoke off-domain during login name=\(name) host=\(offHost)")
                } else {
                    Log.service.error("Service.invoke off-domain name=\(name) host=\(offHost)")
                }
                return .failure(EvalError.offDomain)
            }
            Log.service.info("Service.invoke start id=\(invocation) name=\(name) page=\(pageKind(for: session)) session=\(session.logLabel) nav=\(startingNavigation)/\(session.finishedNavigationGeneration) host=\(host) args=\(args.logShape)")
            do {
                try await manager.requireInvocationAccess(for: self)
                let binding = try await session.bind(self)
                if let selectedSession, WebSessionContract.isEnabled(definition),
                   actionId != WebSessionContract.loginAction, actionId != WebSessionContract.listAction {
                    guard await approveInvocation(WebSessionContract.listAction, input: .object([:])) else {
                        throw InvokeError.denied("\(domain):\(WebSessionContract.listAction)")
                    }
                    try Task.checkCancellation()
                    try await manager.requireInvocationAccess(for: self)
                    guard owns(session), session.navigationGeneration == startingNavigation else {
                        throw EvalError.contextInvalidated
                    }
                    let probe = "return await window.ox.callServiceAction('listSessions', {});"
                    let rawSessions = try await binding.evaluate(probe)
                    let sessions = rawSessions.map(JSONValue.from) ?? .null
                    try WebSessionContract.validateSessions(sessions, domain: domain)
                    guard sessions.arrayValue?.contains(selectedSession) == true else {
                        Log.service.warning("Service.session unavailable domain=\(domain) page=\(session.logLabel)")
                        throw OxFunctionError(code: "authentication_required", message: "The selected logged-in session is no longer available. No action was executed.", recovery: "Use checkAccess to rediscover sessions and select the intended account/tenant, or requestAccess if login is needed. Do not silently switch accounts or automatically replay writes.")
                    }
                    guard session.navigationGeneration == startingNavigation else { throw EvalError.contextInvalidated }
                    updateSessionPage(session, session: selectedSession)
                }
                session.lastInvocation = (invocationID, domain, actionId, args, requestedSession, pageURL, selectedSession, Date())
                session.secretAttempt = secrets
                session.frameSecretContext = (self, binding.document.id)
                let raw = try await binding.evaluate(source)
                let value = raw.map(JSONValue.from) ?? .null
                if WebSessionContract.isEnabled(definition), actionId == WebSessionContract.listAction {
                    try WebSessionContract.validateSessions(value, domain: domain)
                }
                let outputViolations = JSONSchemaValidator.validate(value, against: outputSchema, definitions: definitions)
                if !outputViolations.isEmpty {
                    Log.service.error("Service.invoke invalid-output id=\(invocation) name=\(name) session=\(session.logLabel) ms=\(elapsedMs()) violations=\(InvokeError.describe(outputViolations))")
                    return .failure(InvokeError.invalidOutput(name, outputViolations))
                }
                if WebSessionContract.isEnabled(definition), actionId == WebSessionContract.listAction,
                   session.navigationGeneration == startingNavigation,
                   let sessions = value.arrayValue, sessions.count <= 1 {
                    updateSessionPage(session, session: sessions.first)
                }
                Log.service.info("Service.invoke result id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration) ms=\(elapsedMs()) value=\(value.logShape)")
                return .success(secrets?.redact(value) ?? value)
            } catch EvalError.contextInvalidated {
                if WebSessionContract.isEnabled(definition), actionId == WebSessionContract.loginAction,
                   session.navigationGeneration != startingNavigation {
                    Log.service.info("Service.login navigation-prepared domain=\(domain) page=\(session.logLabel)")
                    return .success(.null)
                }
                Log.service.warning("Service.invoke interrupted-navigation id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration) state=\(resolutionState.logLabel) ms=\(elapsedMs())")
                return .failure(EvalError.contextInvalidated)
            } catch {
                let message = secrets?.redact(error.localizedDescription) ?? error.localizedDescription
                Log.service.error("Service.invoke error id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration) state=\(resolutionState.logLabel) ms=\(elapsedMs()) error=\(LogPrivacy.text(message))")
                return .failure(secrets == nil ? error : RuntimeError.bridge(message))
            }
        }

        do {
            if let targetPage {
                return try await manager.actionScheduler.schedule(pageAction, on: targetPage) { page in
                    await evaluate(in: page, startingNavigation: page.navigationGeneration)
                }
            }
            let page = try await openSessionPage(for: pageAction)
            return try await manager.actionScheduler.schedule(pageAction, on: page, destination: pageAction.baseURL) { page in
                await evaluate(in: page, startingNavigation: page.navigationGeneration)
            }
        } catch {
            Log.service.error("Service.invoke page-failed id=\(invocation) name=\(name) error=\(LogPrivacy.text(error.localizedDescription))")
            return .failure(error)
        }
    }

    func executeBrowserJavaScript(
        _ script: String,
        action: Action,
        in page: BrowserSession,
        frame: BrowserSession.FrameTarget? = nil,
        verify: @escaping @MainActor @Sendable (BrowserSession) throws -> Void
    ) async throws -> JSONValue {
        guard domain == "ios:browser" else { throw EvalError.notActive }
        let name = "ox.web.browser.executeScript"
        let invocationID = UUID()
        let invocation = String(invocationID.uuidString.prefix(8))
        let started = Date()
        return try await manager.actionScheduler.schedule(action, on: page, name: name) { page in
            let startingNavigation = page.navigationGeneration
            guard self.owns(page) else { throw EvalError.contextInvalidated }
            try verify(page)
            let host = page.page.url?.host ?? "blank"
            Log.service.info("Service.dangerousBrowser start id=\(invocation) domain=\(self.domain) session=\(page.logLabel) nav=\(startingNavigation)/\(page.finishedNavigationGeneration) host=\(host) bytes=\(script.utf8.count)")
            do {
                try await self.manager.requireInvocationAccess(for: self)
                let raw = try await self.evalOnce(page, frame?.guarded(script) ?? script, timeout: 30, frame: frame?.info)
                let value = raw.map(JSONValue.from) ?? .null
                Log.service.info("Service.dangerousBrowser result id=\(invocation) domain=\(self.domain) session=\(page.logLabel) nav=\(startingNavigation)->\(page.navigationGeneration)/\(page.finishedNavigationGeneration) ms=\(Int(Date().timeIntervalSince(started) * 1000)) value=\(value.logShape)")
                return value
            } catch {
                Log.service.error("Service.dangerousBrowser error id=\(invocation) domain=\(self.domain) session=\(page.logLabel) nav=\(startingNavigation)->\(page.navigationGeneration)/\(page.finishedNavigationGeneration) ms=\(Int(Date().timeIntervalSince(started) * 1000)) error=\(LogPrivacy.text(error.localizedDescription))")
                throw error
            }
        }
    }

    // MARK: - Auth

}

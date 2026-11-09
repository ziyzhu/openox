import Foundation
import WebKit

extension Service {
    func advancePage(_ session: ServiceWebPage) {
        guard owns(session) else {
            failQueuedInvocations(in: session, error: EvalError.notActive)
            return
        }
        if case .pending(let lease) = session.navigationPhase,
           activeInvocationCount(in: session) == 0 {
            if transitionNavigation(.reserved(lease), on: session) {
                Log.webView.info("Service.navigation reserved domain=\(domain) session=\(session.logLabel) id=\(lease.id.uuidString.prefix(8)) label=\(lease.label) queued=\(queuedInvocationCount(in: session))")
            }
            return
        }
        guard session.isReady else { return }
        if domain != "ios:browser" {
            guard let host = session.page.url?.host, isServiceHost(host) else {
                transitionNavigation(.serviceDomainLost, on: session)
                return
            }
        }
        manager.actionScheduler.advance(session)
    }

    func failQueuedInvocations(in session: ServiceWebPage, error: any Error) {
        manager.actionScheduler.failPending(on: session, error: error)
    }

    func invokeAction(
        _ actionId: String,
        args: JSONValue,
        role: InvocationRole = .standard,
        session requestedSession: JSONValue? = nil,
        pageURL: String? = nil,
        in ownedPage: ServiceWebPage? = nil,
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
        guard let inputSchema = action.inputSchema, let outputSchema = action.outputSchema else {
            return .failure(InvokeError.invalidContract(name))
        }
        let definitions = definition.definitions
        let inputViolations = JSONSchemaValidator.validate(args, against: inputSchema, definitions: definitions)
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
        let selectedSession: JSONValue?
        let destination: URL
        do {
            if ownedPage == nil {
                selectedSession = try await invocationSession(action: action, session: requestedSession, pageURL: pageURL, approve: approve)
            } else {
                selectedSession = requestedSession
                if WebSessionContract.isEnabled(definition), action.requireAuth, selectedSession == nil {
                    throw InvokeError.requiresAuth(name)
                }
            }
            destination = try executionURL(defaultURL: actionBaseURL, session: selectedSession, pageURL: pageURL)
            Log.service.info("Service.invoke routing id=\(invocation) name=\(name) source=\(pageURL == nil ? "manifest" : "pageUrl") selectedSession=\(selectedSession != nil) destination=\(LogPrivacy.url(destination.absoluteString))")
            try Task.checkCancellation()
        } catch { return .failure(error) }
        let pageAction = Action(
            service: self,
            definition: action,
            baseURL: destination,
            role: actionId == WebSessionContract.loginAction && role == .standard ? .blockingAction : role,
            scripts: scripts,
            session: selectedSession
        )
        let argsJSON = (try? JSONEncoder().encode(args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let idJSON = (try? JSONEncoder().encode(actionId))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let sessionJSON = selectedSession.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let source = "return await window.ox.callServiceAction(\(idJSON), \(argsJSON), { session: \(sessionJSON) });"

        func evaluate(in session: ServiceWebPage, startingNavigation: Int) async -> Result<JSONValue, Error> {
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
                    let probe = "return await window.ox.callServiceAction('listSessions', {}, { session: \(sessionJSON) });"
                    let rawSessions = try await evalAsync(session, probe, context: "sessions:\(invocation)")
                    let sessions = rawSessions.map(JSONValue.from) ?? .null
                    try WebSessionContract.validateSessions(sessions, domain: domain)
                    guard sessions.arrayValue?.contains(selectedSession) == true else {
                        Log.service.warning("Service.session unavailable domain=\(domain) page=\(session.logLabel)")
                        throw OxFunctionError(code: "authentication_required", message: "The selected logged-in session is no longer available. No action was executed.", recovery: "Use checkAccess to rediscover sessions and select the intended account/tenant, or requestAccess if login is needed. Do not silently switch accounts or automatically replay writes.")
                    }
                    guard session.navigationGeneration == startingNavigation else { throw EvalError.contextInvalidated }
                }
                session.lastInvocation = (invocationID, actionId, args, requestedSession, pageURL, selectedSession, Date())
                let raw = try await evalAsync(session, source, context: "invoke:\(invocation)")
                let value = raw.map(JSONValue.from) ?? .null
                if WebSessionContract.isEnabled(definition), actionId == WebSessionContract.listAction {
                    try WebSessionContract.validateSessions(value, domain: domain)
                }
                let outputViolations = JSONSchemaValidator.validate(value, against: outputSchema, definitions: definitions)
                if !outputViolations.isEmpty {
                    Log.service.error("Service.invoke invalid-output id=\(invocation) name=\(name) session=\(session.logLabel) ms=\(elapsedMs()) violations=\(InvokeError.describe(outputViolations))")
                    return .failure(InvokeError.invalidOutput(name, outputViolations))
                }
                Log.service.info("Service.invoke result id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration) ms=\(elapsedMs()) value=\(value.logShape)")
                return .success(value)
            } catch EvalError.contextInvalidated {
                if WebSessionContract.isEnabled(definition), actionId == WebSessionContract.loginAction,
                   session.navigationGeneration != startingNavigation {
                    Log.service.info("Service.login navigation-prepared domain=\(domain) page=\(session.logLabel)")
                    return .success(.null)
                }
                Log.service.warning("Service.invoke interrupted-navigation id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration) state=\(resolutionState.logLabel) ms=\(elapsedMs())")
                return .failure(EvalError.contextInvalidated)
            } catch {
                Log.service.error("Service.invoke error id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration) state=\(resolutionState.logLabel) ms=\(elapsedMs()) error=\(LogPrivacy.text(error.localizedDescription))")
                return .failure(error)
            }
        }

        do {
            if let ownedPage {
                return try await manager.actionScheduler.schedule(pageAction, on: ownedPage) { page in
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
        in page: ServiceWebPage,
        verify: @escaping @MainActor @Sendable (ServiceWebPage) throws -> Void
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
                let raw = try await self.evalAsync(page, script, context: "dangerous-web:\(invocation)")
                let value = raw.map(JSONValue.from) ?? .null
                Log.service.info("Service.dangerousBrowser result id=\(invocation) domain=\(self.domain) session=\(page.logLabel) nav=\(startingNavigation)->\(page.navigationGeneration)/\(page.finishedNavigationGeneration) ms=\(Int(Date().timeIntervalSince(started) * 1000)) value=\(value.logShape)")
                return value
            } catch {
                Log.service.error("Service.dangerousBrowser error id=\(invocation) domain=\(self.domain) session=\(page.logLabel) nav=\(startingNavigation)->\(page.navigationGeneration)/\(page.finishedNavigationGeneration) ms=\(Int(Date().timeIntervalSince(started) * 1000)) error=\(LogPrivacy.text(error.localizedDescription))")
                throw error
            }
        }
    }

    func evalAsync(
        _ session: ServiceWebPage,
        _ js: String,
        context: String,
        timeout: TimeInterval = 30
    ) async throws -> Any? {
        let generation = session.navigationGeneration
        do {
            return try await evalOnce(session, js, timeout: timeout)
        } catch EvalError.contextInvalidated {
            Log.service.warning("Service.eval context-invalidated context=\(context) session=\(session.logLabel) nav=\(generation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration)")
            throw EvalError.contextInvalidated
        }
    }

    func evalOnce(_ session: ServiceWebPage, _ js: String, timeout: TimeInterval) async throws -> Any? {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, any Error>) in
                let timeoutTask = Task { @MainActor [weak session] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    session?.finishEvaluation(id, with: .failure(EvalError.timeout(timeout)))
                }
                let evaluationTask = Task { @MainActor [weak session] in
                    guard let session else { return }
                    do {
                        let value = try await session.page.callJavaScript(
                            js,
                            arguments: [:],
                            in: nil,
                            contentWorld: .page
                        )
                        session.finishEvaluation(id, with: .success(value))
                    } catch {
                        session.finishEvaluation(id, with: .failure(Self.evalError(error)))
                    }
                }
                session.pendingEvaluations[id] = ServiceWebPage.PendingEvaluation(
                    continuation: continuation,
                    timeout: timeoutTask,
                    evaluation: evaluationTask
                )
            }
        } onCancel: {
            Task { @MainActor [weak session] in
                session?.finishEvaluation(id, with: .failure(CancellationError()))
            }
        }
    }

    nonisolated private static func evalError(_ error: any Error) -> any Error {
        let nsError = error as NSError
        let message = (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String)
            ?? (nsError.userInfo[NSLocalizedDescriptionKey] as? String)
            ?? error.localizedDescription
        if message.localizedCaseInsensitiveContains("completion handler for function call is no longer reachable") {
            return EvalError.contextInvalidated
        }
        return EvalError.js(message)
    }

    // MARK: - Auth

}

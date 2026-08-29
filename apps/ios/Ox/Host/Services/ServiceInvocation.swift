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
        in ownedPage: ServiceWebPage? = nil,
        approve: (@MainActor (_ action: String, _ args: Any?) async -> Bool)? = nil
    ) async -> Result<JSONValue, Error> {
        let name = "\(domain):\(actionId)"
        guard hasWebRuntime else { return .failure(InvokeError.unknown(name)) }
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
        let pageAction = Action(
            service: self,
            definition: action,
            baseURL: actionBaseURL,
            role: role,
            scripts: scripts
        )
        if action.requireApproval {
            let allow = await approve?(name, args.toAny()) ?? false
            Log.service.info("Service.invoke approval name=\(name) allow=\(allow)")
            if !allow { return .failure(InvokeError.denied(name)) }
        }
        if !role.isAuthenticationProbe {
            do {
                try await awaitAuthenticationAvailability(name: name)
            } catch {
                return .failure(error)
            }
        }
        if action.requireAuth {
            let initialAuth = auth.logLabel
            let previousObservation = auth.observation
            await resolveSignInState(reason: .requireAuth)
            if auth.isSignedOut { await attemptSilentSignIn(reason: .requireAuth) }
            let decision = auth.isSignedIn
                ? (auth.observation == previousObservation ? "cachedSignedIn" : "probePassed")
                : (auth.isUnavailable
                    ? "probeUnavailable"
                    : auth.observation == previousObservation ? "cachedSignedOut" : "probeDenied")
            Log.service.info("Service.authGate name=\(name) id=\(invocation) decision=\(decision) initial=\(initialAuth) final=\(auth.logLabel)")
            if auth.isUnavailable {
                return .failure(InvokeError.authUnavailable(name))
            }
            guard auth.isSignedIn else {
                Log.service.info("Service.invoke requiresAuth name=\(name) auth=\(auth.logLabel)")
                return .failure(InvokeError.requiresAuth(name))
            }
        }
        let argsJSON = (try? JSONEncoder().encode(args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let idJSON = (try? JSONEncoder().encode(actionId))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let source = "return await window.ox.callServiceAction(\(idJSON), \(argsJSON));"

        func evaluate(in session: ServiceWebPage, startingNavigation: Int) async -> Result<JSONValue, Error> {
            guard owns(session), session.navigationGeneration == startingNavigation else {
                Log.service.error("Service.invoke stale-admission id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration) state=\(resolutionState.logLabel)")
                return .failure(EvalError.contextInvalidated)
            }
            guard let host = session.page.url?.host, isServiceHost(host) else {
                let offHost = session.page.url?.host ?? "?"
                if auth.isSigningIn {
                    Log.service.info("Service.invoke off-domain during sign-in name=\(name) host=\(offHost)")
                } else {
                    Log.service.error("Service.invoke off-domain name=\(name) host=\(offHost)")
                }
                return .failure(EvalError.offDomain)
            }
            Log.service.info("Service.invoke start id=\(invocation) name=\(name) page=\(pageKind(for: session)) session=\(session.logLabel) nav=\(startingNavigation)/\(session.finishedNavigationGeneration) host=\(host) args=\(args.logShape)")
            do {
                let raw = try await evalAsync(session, source, context: "invoke:\(invocation)")
                let value = raw.map(JSONValue.from) ?? .null
                let outputViolations = JSONSchemaValidator.validate(value, against: outputSchema, definitions: definitions)
                if !outputViolations.isEmpty {
                    Log.service.error("Service.invoke invalid-output id=\(invocation) name=\(name) session=\(session.logLabel) ms=\(elapsedMs()) violations=\(InvokeError.describe(outputViolations))")
                    return .failure(InvokeError.invalidOutput(name, outputViolations))
                }
                Log.service.info("Service.invoke result id=\(invocation) name=\(name) session=\(session.logLabel) nav=\(startingNavigation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration) ms=\(elapsedMs()) value=\(value.logShape)")
                return .success(value)
            } catch EvalError.contextInvalidated {
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
            return try await manager.actionScheduler.schedule(pageAction) { page in
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
        in page: ServiceWebPage
    ) async throws -> JSONValue {
        guard domain == "ios:browser" else { throw EvalError.notActive }
        let name = "ios:browser:executeScript"
        let invocationID = UUID()
        let invocation = String(invocationID.uuidString.prefix(8))
        let started = Date()
        return try await manager.actionScheduler.schedule(action, on: page, name: name) { page in
            let startingNavigation = page.navigationGeneration
            guard self.owns(page) else { throw EvalError.contextInvalidated }
            let host = page.page.url?.host ?? "blank"
            Log.service.info("Service.dangerousBrowser start id=\(invocation) domain=\(self.domain) session=\(page.logLabel) nav=\(startingNavigation)/\(page.finishedNavigationGeneration) host=\(host) bytes=\(script.utf8.count)")
            do {
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

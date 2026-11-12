import Foundation
import WebKit

extension ServiceOperations {
    func invokeFrameAction(service: Service, actionID: String, input: JSONValue, frameID: String,
                           session: JSONValue?, secrets: SecretAttempt?, purpose: String) async throws -> JSONValue {
        guard service.isWebService, attachedDomains().contains(service.domain),
              let definition = service.definition.action(actionID, includingStandard: true) else {
            throw RuntimeError.bridge("Frame actions require an attached web service.")
        }
        var pages = serviceManager.services.filter { attachedDomains().contains($0.domain) }
            .flatMap { owner in owner.servicePages.map { (owner, $0) } }
        if let browserPage = serviceManager.browserActionSessions.session(for: serviceManager.browserService, ownerID: native.id).page {
            pages.append((serviceManager.browserService, browserPage))
        }
        let matches = pages.filter { $0.1.frameTargets[frameID] != nil }
        guard matches.count == 1, let (owner, page) = matches.first else {
            throw RuntimeError.bridge("Frame is unavailable or ambiguous. Inspect getPageState again before invoking.")
        }
        if actionID == WebSessionContract.loginAction,
           !owner.isWebService || !WebSessionContract.isEnabled(owner.definition) {
            throw RuntimeError.bridge("Embedded login requires a prepared consumer service page. Inspect that service's page instead of Browser.")
        }
        guard page.secretAttempt?.holdsValues != true else { throw Service.EvalError.contextInvalidated }
        try await owner.installFrameServices(serviceManager.services.filter { attachedDomains().contains($0.domain) }, on: page)
        let frame = try await page.requireFrame(frameID, owner: owner)
        guard let host = URL(string: frame.origin)?.host, service.isServiceHost(host),
              let baseURL = page.page.url else { throw Service.EvalError.offDomain }
        let qualified = service.definition.qualifiedActionName(actionID)
        let scheduled = Service.Action(service: owner, definition: definition, baseURL: baseURL,
                                       role: .blockingAction, scripts: page.actions)
        let result = try await serviceManager.actionScheduler.schedule(scheduled, on: page, name: qualified) { page in
            try await self.serviceManager.requireInvocationAccess(for: service)
            try await self.serviceManager.requireInvocationAccess(for: owner)
            let current = try await page.requireFrame(frameID, owner: owner)
            guard current.origin == frame.origin, page.secretAttempt == nil else { throw Service.EvalError.contextInvalidated }
            let installed = "return window.__oxInstalledService?.startsWith(\(JSONValue.string(service.domain + ":").jsonString())) === true;"
            guard try await owner.evalOnce(page, current.guarded(installed), timeout: 3, frame: current.info) as? Bool == true else {
                throw RuntimeError.bridge("The selected frame belongs to another attached service. Select its matching service before invoking.")
            }
            if definition.requireAuth || session != nil {
                guard WebSessionContract.isEnabled(service.definition) else { throw Service.InvokeError.requiresAuth(qualified) }
                try await self.requireApproval(service.definition.qualifiedActionName(WebSessionContract.listAction), .allow, nil, purpose, nil)
                let probe = try await owner.evalOnce(page, current.guarded("return await window.ox.callServiceAction('listSessions', {});"), timeout: 30, frame: current.info)
                let sessions = probe.map(JSONValue.from) ?? .null
                try WebSessionContract.validateSessions(sessions, domain: service.domain)
                guard let values = sessions.arrayValue, !values.isEmpty,
                      session.map({ values.contains($0) }) ?? true else { throw Service.InvokeError.requiresAuth(qualified) }
            }
            page.secretAttempt = secrets
            page.frameSecretContext = (service, frameID)
            defer {
                page.secretAttempt = nil
                page.frameSecretContext = nil
                SecretRequestGuard.remove(from: page)
                secrets?.releaseRendering()
            }
            let source = "return await window.ox.callServiceAction(\(JSONValue.string(actionID).jsonString()), \(input.jsonString()));"
            let login = actionID == WebSessionContract.loginAction
            let fingerprint = "return JSON.stringify((await (async () => { \(BrowserPageState.script(selector: nil)) })()).controls);"
            var value: JSONValue = .null
            steps: for step in 0..<(login && secrets != nil ? 5 : 1) {
                let before = login ? try await owner.evalOnce(page, current.guarded(fingerprint), timeout: 3, frame: current.info) as? String : nil
                let retrievals = secrets?.retrievals ?? 0
                var raw: Any?
                for _ in 0..<2 {
                    do { raw = try await owner.evalOnce(page, current.guarded(source), timeout: 30, frame: current.info) }
                    catch {
                        if secrets?.awaitingApproval.isEmpty != false {
                            if login, (secrets?.retrievals ?? 0) > retrievals,
                               (try? await page.requireFrame(frameID, owner: owner)) == nil { break steps }
                            throw error
                        }
                    }
                    if secrets?.awaitingApproval.isEmpty != false { break }
                    guard await secrets?.authorizePending() == true else { throw SecretAttemptError.denied }
                }
                value = raw.map(JSONValue.from) ?? .null
                let violations = JSONSchemaValidator.validate(value, against: definition.outputSchema ?? .null, definitions: service.definition.definitions)
                guard violations.isEmpty else { throw Service.InvokeError.invalidOutput(qualified, violations) }
                guard login, (secrets?.retrievals ?? 0) > retrievals, step < 4 else { break }
                try await Task.sleep(for: .milliseconds(1500))
                guard let after = try? await owner.evalOnce(page, current.guarded(fingerprint), timeout: 3, frame: current.info) as? String,
                      after != before else { break }
            }
            Log.service.info("Service.frame invoked service=\(service.domain) owner=\(owner.domain) action=\(actionID) frame=\(frameID) origin=\(frame.origin)")
            return secrets?.redact(value) ?? value
        }
        guard actionID == WebSessionContract.loginAction else { return result }
        guard owner.isWebService, WebSessionContract.isEnabled(owner.definition) else {
            throw RuntimeError.bridge("Embedded login requires a prepared consumer service page. Inspect that service's page instead of Browser.")
        }
        let approve: @MainActor (String, Any?) async -> Bool = { name, args in
            do { try await self.requireApproval(name, .allow, args, purpose, nil); return true }
            catch { return false }
        }
        if await settledSession(service: owner, secrets: secrets, page: page, approve: approve) {
            return .object(["interaction": .string("automatic"), "authentication": .string("verified")])
        }
        return try await handOffLogin(service: owner, secrets: secrets, input: .object([:]), session: nil,
                                     pageURL: nil, prepare: false, approve: approve)
    }
}

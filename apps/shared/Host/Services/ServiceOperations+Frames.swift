import Foundation
import WebKit

extension ServiceOperations {
    func invokeFrameAction(service: Service, actionID: String, input: JSONValue, frameID: String,
                           session: JSONValue?, secrets: SecretAttempt?, purpose: String) async throws -> JSONValue {
        guard service.isWebService, attachedDomains().contains(service.domain),
              let definition = service.definition.action(actionID, includingStandard: true) else {
            throw RuntimeError.bridge("Frame actions require an attached web service.")
        }
        let matches = serviceManager.browserSessions.sessions.filter {
            $0.scopeID == native.id && $0.frameTargets[frameID] != nil
        }
        guard matches.count == 1, let page = matches.first else {
            throw RuntimeError.bridge("Frame is unavailable or ambiguous. Inspect getPageState again before invoking.")
        }
        let owner = serviceManager.services.first { $0.servicePages.contains { $0 === page } } ?? serviceManager.browserService
        if actionID == WebSessionContract.loginAction,
           !owner.isWebService || !WebSessionContract.isEnabled(owner.definition) {
            throw RuntimeError.bridge("Embedded login requires a prepared consumer service page. Inspect that service's page instead of Browser.")
        }
        guard page.secretAttempt?.holdsValues != true else { throw Service.EvalError.contextInvalidated }
        let frame = try await page.requireFrame(frameID)
        guard let host = URL(string: frame.origin)?.host, service.isServiceHost(host),
              let baseURL = page.page.url else { throw Service.EvalError.offDomain }
        let qualified = service.definition.qualifiedActionName(actionID)
        let scheduled = Service.Action(service: service, definition: definition, baseURL: baseURL,
                                       role: .blockingAction, scripts: service.resolutionState.resolved?.actions ?? "")
        let result = try await serviceManager.actionScheduler.schedule(scheduled, on: page, name: qualified) { page in
            try await self.serviceManager.requireInvocationAccess(for: service)
            try await self.serviceManager.requireInvocationAccess(for: owner)
            guard page.secretAttempt == nil else { throw Service.EvalError.contextInvalidated }
            let binding = try await page.bind(service, frameID: frameID)
            let current = binding.document
            guard current.origin == frame.origin else { throw Service.EvalError.contextInvalidated }
            if definition.requireAuth || session != nil {
                guard WebSessionContract.isEnabled(service.definition) else { throw Service.InvokeError.requiresAuth(qualified) }
                try await self.requireApproval(service.definition.qualifiedActionName(WebSessionContract.listAction), .allow, nil, purpose, nil)
                let probe = try await binding.evaluate("return await window.ox.callServiceAction('listSessions', {});")
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
            var raw: Any?
            for attempt in 0..<2 {
                do { raw = try await binding.evaluate(source) }
                catch {
                    if secrets?.awaitingApproval.isEmpty != false {
                        if actionID == WebSessionContract.loginAction, page.navigationGeneration != binding.generation {
                            break
                        }
                        throw error
                    }
                }
                guard let secrets, !secrets.awaitingApproval.isEmpty, attempt == 0 else { break }
                guard await secrets.authorizePending() else { throw SecretAttemptError.denied }
            }
            let value = raw.map(JSONValue.from) ?? .null
            let violations = JSONSchemaValidator.validate(value, against: definition.outputSchema ?? .null, definitions: service.definition.definitions)
            guard violations.isEmpty else { throw Service.InvokeError.invalidOutput(qualified, violations) }
            Log.service.info("Service.frame invoked service=\(service.domain) owner=\(owner.domain) action=\(actionID) frame=\(frameID) origin=\(frame.origin)")
            return secrets?.redact(value) ?? value
        }
        guard actionID == WebSessionContract.loginAction else { return result }
        return try await completeLogin(service: owner, input: input, page: page)
    }
}

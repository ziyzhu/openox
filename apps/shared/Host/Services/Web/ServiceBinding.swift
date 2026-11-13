import Foundation

@MainActor
struct ServiceBinding {
    let service: Service
    let session: BrowserSession
    let document: BrowserSession.FrameTarget
    let generation: Int

    func evaluate(_ source: String, timeout: TimeInterval = 30) async throws -> Any? {
        try await service.manager.requireInvocationAccess(for: service)
        guard session.isOpen, session.navigationGeneration == generation else {
            throw Service.EvalError.contextInvalidated
        }
        guard let host = URL(string: document.origin)?.host, service.isServiceHost(host) else {
            throw Service.EvalError.offDomain
        }
        let guarded = """
        if (!window.__oxInstalledService?.startsWith(\(JSONValue.string(service.domain + ":").jsonString()))) throw Error('Service binding changed; inspect the document again');
        \(source)
        """
        return try await session.evalOnce(session, document.guarded(guarded), timeout: timeout, frame: document.info)
    }

    func validate() async throws {
        _ = try await evaluate("return true;", timeout: 3)
    }
}

extension BrowserSession {
    func bind(_ service: Service, frameID: String? = nil) async throws -> ServiceBinding {
        guard isOpen, secretAttempt == nil else { throw Service.EvalError.contextInvalidated }
        let expectedGeneration = navigationGeneration
        try await installFrameServices([service], on: self)
        guard isOpen, navigationGeneration == expectedGeneration else { throw Service.EvalError.contextInvalidated }
        guard let document = frameTargets.values.first(where: { target in frameID.map { $0 == target.id } ?? target.isMainFrame }) else {
            throw Service.EvalError.notReady
        }
        let binding = ServiceBinding(service: service, session: self, document: document, generation: navigationGeneration)
        try await binding.validate()
        Log.service.info("BrowserSession.bound session=\(logLabel) service=\(service.domain) document=\(document.id) main=\(document.isMainFrame)")
        return binding
    }
}

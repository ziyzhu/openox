#if targetEnvironment(simulator)
import Foundation
import WebKit

extension OxHostProtocol {
    @MainActor
    static func handleSetAttachedService(
        _ command: SetAttachedServiceRequest,
        chatManager: ChatManager,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard let session = chatManager.current else {
            reply(encode(StatusResult(kind: "set-attached-service-result", id: command.id, error: "session unavailable")))
            return
        }
        let domains = command.domains ?? command.domain.map { [$0] } ?? []
        guard !domains.isEmpty else {
            session.setAttachedServices([])
            reply(encode(StatusResult(kind: "set-attached-service-result", id: command.id)))
            return
        }
        let services = domains.compactMap { serviceManager.service(domain: $0) }
        guard services.count == domains.count else {
            let missing = domains.filter { domain in !services.contains { $0.domain == domain } }
            reply(encode(StatusResult(kind: "set-attached-service-result", id: command.id, error: "unknown service: \(missing.joined(separator: ", "))")))
            return
        }
        session.setAttachedServices(services)
        reply(encode(StatusResult(kind: "set-attached-service-result", id: command.id)))
    }

    @MainActor

    struct ActionPayload {
        let ok: Bool
        let value: JSONValue?
        let error: String?
    }

    struct ActionResult: Encodable {
        let kind: String
        let id: String
        let ok: Bool
        let value: JSONValue?
        let error: String?

        init(kind: String, id: String, payload: ActionPayload) {
            self.kind = kind
            self.id = id
            self.ok = payload.ok
            self.value = payload.value
            self.error = payload.error
        }
    }


    struct SyncMonoRepositoryResult: Encodable {
        let kind = "sync-mono-repository-result"
        let id: String
        let ok: Bool
        let error: JSONValue
        let head: JSONValue
        let changed: [String]
        let services: Int
    }

    struct PageRow: Encodable {
        let url: JSONValue
        let title: JSONValue
        let isLoading: Bool
        let progress: Double
        let canGoBack: Bool
        let canGoForward: Bool
    }

    struct ServiceRow: Encodable {
        let domain: String
        let title: String
        let phase: String
        let navigation: String
        let activeInvocations: Int
        let queuedInvocations: Int
        let pendingEvaluations: Int
        let pageCount: Int
        let signIn: String
        let page: PageRow?
        let manifest: JSONValue?
        let favicon: String?
    }

    struct ListServicesResult: Encodable {
        let kind = "list-services-result"
        let id: String
        let ok = true
        let services: [ServiceRow]
    }

    @MainActor

    static func handleInvokeAction(
        _ command: ActionRequest,
        chatManager: ChatManager,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        let domain = command.domain
        let action = command.action
        let args = command.args ?? .object([:])

        guard !command.id.isEmpty, !domain.isEmpty, !action.isEmpty else {
            reply(encode(StatusResult(kind: "action-result", id: command.id, error: "missing id/domain/action")))
            return
        }
        Log.agent.debug("OxHostProtocol.invoke-action id=\(command.id) \(domain):\(action)")
        withService(id: command.id, domain: domain, kind: "action-result", serviceManager: serviceManager, reply: reply) { svc in
            if svc.isMCPService {
                guard await svc.loadManifest(reason: .debug) != nil else {
                    return ActionPayload(ok: false, value: nil, error: "service capabilities unavailable")
                }
            }
            if let iOSService = svc.iOSService {
                guard let session = chatManager.current else {
                    return ActionPayload(ok: false, value: nil, error: "session unavailable")
                }
                return resultPayload(await iOSService.invoke(
                    service: svc,
                    actionID: action,
                    args: args,
                    purpose: "Debug invocation",
                    approve: { _, _ in command.approve ?? true },
                    nativeInvocation: { serviceID, actionID, args, purpose in
                        try await session.debugInvokeIOSService(serviceID, actionID: actionID, args: args, purpose: purpose)
                    }
                ))
            }
            if let mcpService = svc.remoteMCPService {
                return resultPayload(await mcpService.invoke(
                    service: svc,
                    actionID: action,
                    args: args,
                    approve: { _, _ in command.approve ?? true }
                ))
            }
            return resultPayload(await svc.invokeAction(action, args: args, approve: { _, _ in command.approve ?? true }))
        }
    }

    @MainActor
    static func handleEvaluate(
        _ command: EvaluateRequest,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        let domain = command.domain
        let script = command.script

        guard !command.id.isEmpty, !domain.isEmpty, !script.isEmpty else {
            reply(encode(StatusResult(kind: "evaluate-result", id: command.id, error: "missing id/domain/script")))
            return
        }
        Log.agent.debug("OxHostProtocol.evaluate id=\(command.id) domain=\(domain) bytes=\(script.utf8.count)")
        withService(id: command.id, domain: domain, kind: "evaluate-result", serviceManager: serviceManager, reply: reply) { svc in
            resultPayload(await svc.debugEvaluate(script))
        }
    }

    @MainActor
    static func handleReloadService(
        _ command: ServiceRequest,
        chatManager: ChatManager,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard !command.id.isEmpty, !command.domain.isEmpty else {
            reply(encode(StatusResult(kind: "reload-service-result", id: command.id, error: "missing id/domain")))
            return
        }
        Log.agent.debug("OxHostProtocol.reload-service id=\(command.id) domain=\(command.domain)")
        withService(id: command.id, domain: command.domain, kind: "reload-service-result", serviceManager: serviceManager, reply: reply) { svc in
            let url: URL?
            if svc.domain == "ios:browser" {
                guard let chat = chatManager.current,
                      let session = serviceManager.browserActionSessions.existingSession(for: chat.id, service: svc) else {
                    return ActionPayload(ok: false, value: nil, error: "browser session unavailable")
                }
                url = await session.reload()
            } else {
                url = await svc.reload()
            }
            guard let url else {
                return ActionPayload(ok: false, value: nil, error: "service reload failed")
            }
            return ActionPayload(ok: true, value: .string(url.absoluteString), error: nil)
        }
    }

    @MainActor
    static func handleRefreshServiceAuth(
        _ command: ServiceRequest,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard !command.id.isEmpty, !command.domain.isEmpty else {
            reply(encode(StatusResult(kind: "refresh-service-auth-result", id: command.id, error: "missing id/domain")))
            return
        }
        Log.agent.debug("OxHostProtocol.refresh-service-auth id=\(command.id) domain=\(command.domain)")
        withService(id: command.id, domain: command.domain, kind: "refresh-service-auth-result", serviceManager: serviceManager, reply: reply) { service in
            await service.refreshSignInState(reason: .debug)
            return ActionPayload(ok: true, value: .string(service.signInState.rawValue), error: nil)
        }
    }

    @MainActor

    static func handleSyncMonoRepository(
        _ command: IDRequest,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        Log.agent.debug("OxHostProtocol.sync-mono-repository id=\(command.id)")
        Task { @MainActor in
            let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            let manager = serviceManager
            let changed = if manager.repositories.contains(where: { $0.id == "development" }) {
                await manager.updateRepository("development", locale: locale)
            } else {
                await manager.refreshServices(locale: locale)
            }
            let failure: String? = { if case .failed(let m) = manager.repositoryState { return m }; return nil }()
            Log.agent.debug("OxHostProtocol.sync-mono-repository id=\(command.id) monoRepository=\(manager.monoRepositoryHash ?? "nil") changed=\(changed)")
            reply(encode(SyncMonoRepositoryResult(
                id: command.id,
                ok: failure == nil,
                error: failure.map(JSONValue.string) ?? .null,
                head: manager.monoRepositoryHash.map(JSONValue.string) ?? .null,
                changed: changed,
                services: manager.services.count
            )))
        }
    }

    @MainActor
    static func handleListServices(
        _ command: IDRequest,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        Log.agent.debug("OxHostProtocol.list-services id=\(command.id)")

        Task { @MainActor in
            let mgr = serviceManager
            if mgr.services.isEmpty {
                let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
                await mgr.refreshServices(locale: locale)
            }
            var services: [ServiceRow] = []
            for svc in mgr.services {
                let snapshot = svc.debugSnapshot
                let page = snapshot.page.map {
                    PageRow(
                        url: $0.url.map(JSONValue.string) ?? .null,
                        title: $0.title.map(JSONValue.string) ?? .null,
                        isLoading: $0.isLoading,
                        progress: $0.progress,
                        canGoBack: $0.canGoBack,
                        canGoForward: $0.canGoForward
                    )
                }
                let favicon = await mgr.faviconImage(for: svc.domain).map {
                    "data:image/png;base64,\($0.base64EncodedString())"
                }
                services.append(ServiceRow(
                    domain: svc.domain,
                    title: svc.title,
                    phase: snapshot.phase,
                    navigation: snapshot.navigation,
                    activeInvocations: snapshot.activeInvocations,
                    queuedInvocations: snapshot.queuedInvocations,
                    pendingEvaluations: snapshot.pendingEvaluations,
                    pageCount: snapshot.pageCount,
                    signIn: snapshot.signIn,
                    page: page,
                    manifest: snapshot.manifest,
                    favicon: favicon
                ))
            }
            Log.agent.debug("OxHostProtocol.list-services id=\(command.id) count=\(services.count)")
            reply(encode(ListServicesResult(id: command.id, services: services)))
        }
    }

    @MainActor
    static func withService(
        id: String, domain: String, kind: String,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void,
        body: @escaping @MainActor (Service) async -> ActionPayload
    ) {
        Task { @MainActor in
            let mgr = serviceManager
            if mgr.service(domain: domain) == nil {
                let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
                await mgr.refreshServices(locale: locale)
            }
            guard let svc = mgr.service(domain: domain) else {
                reply(encode(StatusResult(kind: kind, id: id, error: "unknown service: \(domain)")))
                return
            }
            reply(encode(ActionResult(kind: kind, id: id, payload: await body(svc))))
        }
    }

    static func resultPayload(_ result: Result<JSONValue, Error>) -> ActionPayload {
        switch result {
        case .success(let value): return ActionPayload(ok: true, value: value, error: nil)
        case .failure(let error): return ActionPayload(ok: false, value: nil, error: error.localizedDescription)
        }
    }
}
#endif

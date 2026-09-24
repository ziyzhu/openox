#if targetEnvironment(simulator)
import Foundation
import WebKit

extension OxHostProtocol {
    @MainActor
    static func handleSetAttachedService(
        _ command: SetAttachedServiceRequest,
        chatManager: ChatManager,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        guard let session = chatManager.current else {
            reply.failure("session unavailable")
            return
        }
        let domains = command.domains ?? command.domain.map { [$0] } ?? []
        guard !domains.isEmpty else {
            session.setAttachedServices([])
            reply.success()
            return
        }
        let services = domains.compactMap { serviceManager.service(domain: $0) }
        guard services.count == domains.count else {
            let missing = domains.filter { domain in !services.contains { $0.domain == domain } }
            reply.failure("unknown service: \(missing.joined(separator: ", "))")
            return
        }
        session.setAttachedServices(services)
        reply.success()
    }

    struct SyncServicesResult: Encodable {
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
        let services: [ServiceRow]
    }

    @MainActor

    static func handleInvokeAction(
        _ command: ActionRequest,
        chatManager: ChatManager,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        let domain = command.domain
        let action = command.action
        let args = command.args ?? .object([:])

        guard !domain.isEmpty, !action.isEmpty else {
            reply.failure("missing id/domain/action")
            return
        }
        Log.agent.debug("OxHostRPC.services.invoke id=\(reply.id) \(domain):\(action)")
        withService(domain: domain, serviceManager: serviceManager, reply: reply) { svc in
            if svc.isMCPService {
                guard await svc.loadManifest(reason: .debug) != nil else {
                    return .failure(RuntimeError.bridge("service capabilities unavailable"))
                }
            }
            if let apiService = svc.apiService {
                return await apiService.invoke(service: svc, actionID: action, args: args,
                    approve: { _, _ in command.approve ?? false })
            }
            if let iOSService = svc.iOSService {
                guard let session = chatManager.current else {
                    return .failure(RuntimeError.bridge("session unavailable"))
                }
                return await iOSService.invoke(
                    service: svc,
                    actionID: action,
                    args: args,
                    purpose: "Debug invocation",
                    approve: { _, _ in command.approve ?? true },
                    nativeInvocation: { serviceID, actionID, args, purpose in
                        try await session.debugInvokeIOSService(serviceID, actionID: actionID, args: args, purpose: purpose)
                    }
                )
            }
            if let mcpService = svc.remoteMCPService {
                return await mcpService.invoke(
                    service: svc,
                    actionID: action,
                    args: args,
                    approve: { _, _ in command.approve ?? true }
                )
            }
            return await svc.invokeAction(action, args: args, approve: { _, _ in command.approve ?? true })
        }
    }

    @MainActor
    static func handleEvaluate(
        _ command: EvaluateRequest,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        let domain = command.domain
        let script = command.script

        guard !domain.isEmpty, !script.isEmpty else {
            reply.failure("missing id/domain/script")
            return
        }
        Log.agent.debug("OxHostRPC.services.evaluate id=\(reply.id) domain=\(domain) bytes=\(script.utf8.count)")
        withService(domain: domain, serviceManager: serviceManager, reply: reply) { svc in
            await svc.debugEvaluate(script)
        }
    }

    @MainActor
    static func handleReloadService(
        _ command: ServiceRequest,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        guard !command.domain.isEmpty else {
            reply.failure("missing id/domain")
            return
        }
        Log.agent.debug("OxHostRPC.services.reload id=\(reply.id) domain=\(command.domain)")
        withService(domain: command.domain, serviceManager: serviceManager, reply: reply) { svc in
            let url = await svc.reload()
            guard let url else {
                return .failure(RuntimeError.bridge("service reload failed"))
            }
            return .success(.string(url.absoluteString))
        }
    }

    @MainActor
    static func handleRefreshServiceAuth(
        _ command: ServiceRequest,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        guard !command.domain.isEmpty else {
            reply.failure("missing id/domain")
            return
        }
        Log.agent.debug("OxHostRPC.services.refreshAuth id=\(reply.id) domain=\(command.domain)")
        withService(domain: command.domain, serviceManager: serviceManager, reply: reply) { service in
            await service.checkAccess(policy: .current, reason: .debug)
            return .success(.string(service.signInState.rawValue))
        }
    }

    @MainActor

    static func handleSyncServices(
        _ command: EmptyRequest,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        Log.agent.debug("OxHostRPC.services.sync id=\(reply.id)")
        Task { @MainActor in
            let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            let manager = serviceManager
            let changed = if manager.repositories.contains(where: { $0.id == "development" }) {
                await manager.updateRepository("development", locale: locale)
            } else {
                await manager.refreshServices(locale: locale)
            }
            let failure: String? = { if case .failed(let m) = manager.repositoryState { return m }; return nil }()
            Log.agent.debug("OxHostRPC.services.sync id=\(reply.id) monoRepository=\(manager.monoRepositoryHash ?? "nil") changed=\(changed)")
            reply.complete(SyncServicesResult(
                head: manager.monoRepositoryHash.map(JSONValue.string) ?? .null,
                changed: changed,
                services: manager.services.count
            ), error: failure)
        }
    }

    @MainActor
    static func handleListServices(
        _ command: EmptyRequest,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        Log.agent.debug("OxHostRPC.services.list id=\(reply.id)")

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
            Log.agent.debug("OxHostRPC.services.list id=\(reply.id) count=\(services.count)")
            reply.success(ListServicesResult(services: services))
        }
    }

    @MainActor
    static func withService(
        domain: String,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply,
        body: @escaping @MainActor (Service) async -> Result<JSONValue, Error>
    ) {
        Task { @MainActor in
            let mgr = serviceManager
            if mgr.service(domain: domain) == nil {
                let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
                await mgr.refreshServices(locale: locale)
            }
            guard let svc = mgr.service(domain: domain) else {
                reply.failure("unknown service: \(domain)")
                return
            }
            reply.complete(await body(svc))
        }
    }

}
#endif

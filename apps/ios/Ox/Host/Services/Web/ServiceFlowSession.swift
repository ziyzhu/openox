import Foundation
import WebKit

@MainActor
final class ServiceFlowSession {
    let id: UUID
    let kind: ServiceFlowKind
    let service: Service
    let baseURL: URL
    let actionPage: Service.ServiceWebPage
    private(set) var handoffPage: WebPage?

    private var handoffSession: ServiceHandoffSession?

    private init(
        id: UUID,
        kind: ServiceFlowKind,
        service: Service,
        baseURL: URL,
        actionPage: Service.ServiceWebPage
    ) {
        self.id = id
        self.kind = kind
        self.service = service
        self.baseURL = baseURL
        self.actionPage = actionPage
    }

    static func open(
        id: UUID,
        kind: ServiceFlowKind,
        service: Service,
        actionID: String,
        args: JSONValue,
        role: Service.InvocationRole
    ) async throws -> ServiceFlowSession {
        guard let action = await service.resolvedAction(actionID, args: args, role: role) else {
            throw Service.EvalError.notActive
        }
        let page = try await service.openOwnedPage(for: action, owner: .flow(kind, id))
        do {
            try Task.checkCancellation()
        } catch {
            service.closeOwnedPage(page, error: error)
            throw error
        }
        let session = ServiceFlowSession(
            id: id,
            kind: kind,
            service: service,
            baseURL: action.baseURL,
            actionPage: page
        )
        guard service.manager.sessionCoordinator.attach(session) else {
            session.close()
            throw Service.EvalError.contextInvalidated
        }
        return session
    }

    func invoke(
        _ actionID: String,
        args: JSONValue,
        role: Service.InvocationRole
    ) async -> Result<JSONValue, Error> {
        guard let action = await service.resolvedAction(actionID, args: args, role: role),
              action.baseURL == baseURL else {
            Log.service.error("ServiceFlowSession base-url-mismatch domain=\(service.domain) flow=\(id.uuidString.prefix(8)) kind=\(kind.rawValue) action=\(actionID)")
            return .failure(Service.InvokeError.invalidContract("\(service.domain):\(actionID)"))
        }
        return await service.invokeAction(actionID, args: args, role: role, in: actionPage)
    }

    func makeHandoff(
        title: String,
        navigationTitle: String,
        initialURL: URL,
        completionProbe: @escaping @MainActor (URL?) async -> Bool,
        navigationObserver: @escaping @MainActor (WebPage.NavigationEvent, URL?) -> Void = { _, _ in }
    ) -> ServiceHandoffSession {
        precondition(handoffSession == nil)
        let session = ServiceHandoffSession(
            serviceDomain: service.domain,
            title: title,
            navigationTitle: navigationTitle,
            initialURL: initialURL,
            configuration: service.manager.makeHandoffPageConfiguration(for: service.domain),
            completionProbe: completionProbe,
            navigationObserver: navigationObserver
        )
        handoffSession = session
        handoffPage = session.page
        return session
    }

    func close() {
        handoffSession?.cancel()
        handoffSession = nil
        handoffPage = nil
        service.closeOwnedPage(actionPage)
    }
}

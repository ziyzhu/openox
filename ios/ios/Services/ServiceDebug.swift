import Foundation
import WebKit

extension JSONValue {
    var logShape: String {
        switch self {
        case .null: return "null"
        case .array(let a): return "array[\(a.count)]"
        case .object(let o): return "object{\(o.count)}"
        default: return "scalar"
        }
    }
}

#if targetEnvironment(simulator)
@MainActor
final class ServiceDebugSession {
    let id: UUID
    let service: Service
    let page: Service.ServiceWebPage

    private init(id: UUID, service: Service, page: Service.ServiceWebPage) {
        self.id = id
        self.service = service
        self.page = page
    }

    static func open(service: Service, action: Service.Action) async throws -> ServiceDebugSession {
        let id = UUID()
        let page = try await service.openOwnedPage(for: action, owner: .debug(id))
        return ServiceDebugSession(id: id, service: service, page: page)
    }

    func close() {
        service.closeOwnedPage(page)
    }
}

extension Service {
    struct DebugSnapshot {
        struct Page {
            let url: String?
            let title: String?
            let isLoading: Bool
            let progress: Double
            let canGoBack: Bool
            let canGoForward: Bool
        }

        let phase: String
        let navigation: String
        let activeInvocations: Int
        let queuedInvocations: Int
        let pendingEvaluations: Int
        let pageCount: Int
        let signIn: String
        let page: Page?
        let manifest: JSONValue
    }

    var debugSnapshot: DebugSnapshot {
        guard hasWebRuntime else {
            return DebugSnapshot(
                phase: isMCPService ? "MCP" : "iOS",
                navigation: "inactive",
                activeInvocations: 0,
                queuedInvocations: 0,
                pendingEvaluations: 0,
                pageCount: 0,
                signIn: auth.logLabel,
                page: nil,
                manifest: definition.manifest
            )
        }
        let servicePage = servicePages.first
        let phase = servicePage == nil ? resolutionState.logLabel : "active"
        let page = servicePage?.page
        return DebugSnapshot(
            phase: phase,
            navigation: servicePage?.navigationPhase.logLabel ?? "inactive",
            activeInvocations: servicePages.reduce(0) { $0 + activeInvocationCount(in: $1) },
            queuedInvocations: servicePages.reduce(0) { $0 + queuedInvocationCount(in: $1) },
            pendingEvaluations: servicePages.reduce(0) { $0 + $1.pendingEvaluations.count },
            pageCount: pageCount,
            signIn: auth.logLabel,
            page: page.map {
                DebugSnapshot.Page(
                    url: $0.url?.absoluteString,
                    title: $0.title,
                    isLoading: $0.isLoading,
                    progress: $0.estimatedProgress,
                    canGoBack: !$0.backForwardList.backList.isEmpty,
                    canGoForward: !$0.backForwardList.forwardList.isEmpty
                )
            },
            manifest: definition.manifest
        )
    }

    func debugEvaluate(_ script: String) async -> Result<JSONValue, Error> {
        guard let action = await inspectionAction() else {
            return .failure(EvalError.notActive)
        }
        let evaluationID = UUID()
        let evaluation = String(evaluationID.uuidString.prefix(8))
        do {
            let page: ServiceWebPage
            if let debugSession,
               owns(debugSession.page),
               debugSession.page.isReady {
                page = debugSession.page
            } else {
                debugSession?.close()
                let opened = try await ServiceDebugSession.open(service: self, action: action)
                debugSession = opened
                page = opened.page
            }
            return try await manager.actionScheduler.schedule(action, on: page, name: "debug-eval") { page in
                guard self.owns(page) else { return .failure(EvalError.contextInvalidated) }
                Log.service.info("Service.debugEvaluate id=\(evaluation) domain=\(self.domain) session=\(page.logLabel) nav=\(page.navigationGeneration)/\(page.finishedNavigationGeneration) bytes=\(script.utf8.count)")
                do {
                    let raw = try await self.evalAsync(page, script, context: "debug:\(evaluation)")
                    let value = raw.map(JSONValue.from) ?? .null
                    Log.service.info("Service.debugEvaluate result id=\(evaluation) domain=\(self.domain) session=\(page.logLabel) value=\(value.logShape)")
                    return .success(value)
                } catch {
                    Log.service.error("Service.debugEvaluate error id=\(evaluation) domain=\(self.domain) session=\(page.logLabel) error=\(LogPrivacy.text(error.localizedDescription))")
                    return .failure(error)
                }
            }
        } catch {
            return .failure(error)
        }
    }
}
#endif

import Foundation
import WebKit

@MainActor
final class BrowserSession: NSObject {
    enum ScriptMode: String {
        case service
        case browser
    }

    struct PendingEvaluation {
        let continuation: CheckedContinuation<Any?, any Error>
        let timeout: Task<Void, Never>
        let evaluation: Task<Void, Never>
    }

    final class NavigationLease {
        let id = UUID()
        let label: String
        let timeout: TimeInterval
        var reservation: CheckedContinuation<Bool, Never>?
        var completion: CheckedContinuation<URL?, Never>?
        var timeoutTask: Task<Void, Never>?

        init(label: String, timeout: TimeInterval) {
            self.label = label
            self.timeout = timeout
        }

        func settleReservation(_ reserved: Bool) {
            if let reservation {
                self.reservation = nil
                reservation.resume(returning: reserved)
            }
            if !reserved { settleCompletion(nil) }
        }

        func settleCompletion(_ url: URL?) {
            if let completion {
                self.completion = nil
                completion.resume(returning: url)
            }
        }
    }

    final class NavigationLoad {
        let lease: NavigationLease?
        let generation: Int
        var committed = false

        init(lease: NavigationLease?, generation: Int) {
            self.lease = lease
            self.generation = generation
        }
    }

    final class NavigationSettlement {
        let id = UUID()
        let load: NavigationLoad
        let url: URL
        var task: Task<Void, Never>?

        init(load: NavigationLoad, url: URL) {
            self.load = load
            self.url = url
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    enum NavigationPhase {
        case unavailable(String)
        case ready
        case pending(NavigationLease)
        case reserved(NavigationLease)
        case navigating(NavigationLoad)
        case settling(NavigationSettlement)
        case verifying(NavigationLoad, URL)

        var logLabel: String {
            switch self {
            case .unavailable(let reason): return "unavailable:\(reason)"
            case .ready: return "ready"
            case .pending(let lease): return "pending:\(lease.label)"
            case .reserved(let lease): return "reserved:\(lease.label)"
            case .navigating(let load): return "navigating:\(load.lease?.label ?? "external"):\(load.generation)"
            case .settling(let settlement): return "settling:\(settlement.load.lease?.label ?? "external"):\(settlement.load.generation)"
            case .verifying(let load, _): return "verifying:\(load.lease?.label ?? "external"):\(load.generation)"
            }
        }

        var load: NavigationLoad? {
            switch self {
            case .navigating(let load), .verifying(let load, _): load
            case .settling(let settlement): settlement.load
            case .unavailable, .ready, .pending, .reserved: nil
            }
        }

        var settlement: NavigationSettlement? {
            if case .settling(let settlement) = self { settlement } else { nil }
        }
    }

    let id = UUID()
    var scopeID: UUID?
    var lastActiveAt = Date()
    var activeBrowserOperations: Set<UUID> = []
    let page: WebPage
    let navigationDecider: NavigationDecider
    let dialogPresenter: DialogPresenter
    let userContentController: WKUserContentController
    unowned let manager: ServiceManager
    private(set) var isOpen = true
    var additionalUserScripts: [WKUserScript] = []
    var openingTask: Task<Bool, Never>?
    var executionURL: URL?
    var lastInvocation: (id: UUID, domain: String, actionID: String, startedAt: Date)?
    var navigationTask: Task<Void, Never>?
    var navigationGeneration = 0
    var finishedNavigationGeneration = 0
    var navigationStartedAt: Date?
    var navigationPhase: NavigationPhase = .unavailable("new")
    var navigationFailure: String?
    var navigationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var pendingEvaluations: [UUID: PendingEvaluation] = [:]
    var scriptMode: ScriptMode?
    var secretAttempt: SecretAttempt?
    var frameSecretContext: (service: Service, documentID: String)?
    var frameCandidates: [WebPage.FrameInfo] = []
    var omittedFrames = 0
    var frameTargets: [String: FrameTarget] = [:]
    var frameServiceSources: [String: String] = [:]
    let events: BrowserEventLog

    nonisolated static let maximumDialogMessageCharacters = 1_000

    init(manager: ServiceManager) {
        self.manager = manager
        let controller = WKUserContentController()
        var configuration = manager.makePageConfiguration()
        configuration.userContentController = controller
        let decider = NavigationDecider()
        let presenter = DialogPresenter()
        self.page = WebPage(configuration: configuration, navigationDecider: decider, dialogPresenter: presenter)
        self.navigationDecider = decider
        self.dialogPresenter = presenter
        self.userContentController = controller
        self.events = BrowserEventLog(label: String(id.uuidString.prefix(8)))
        super.init()
        decider.session = self
        presenter.session = self
        controller.installBridgeHandlers(self)
        events.install(on: controller)
        controller.addScriptMessageHandler(SecretBridge(page: self), contentWorld: .page, name: SecretBridge.channelName)
        Log.webView.info("BrowserSession.created session=\(logLabel)")
    }

    enum NavigationCommand {
        case load(URLRequest)
        case reload(fromOrigin: Bool)
        case back
        case forward
    }

    enum EvalError: LocalizedError {
        case timeout(TimeInterval)
        case js(String)
        case contextInvalidated
        case navigationTimeout(TimeInterval)
        case navigationFailed(String)
        case notActive
        case notReady
        case offDomain
        var errorDescription: String? {
            switch self {
            case .timeout(let s): return "JS eval timed out after \(Int(s))s"
            case .js(let s): return s
            case .contextInvalidated: return "service page navigated while the action was running"
            case .navigationTimeout(let s): return "service navigation timed out after \(Int(s))s"
            case .navigationFailed(let message): return "service navigation failed: \(message)"
            case .notActive: return "service page failed to load"
            case .notReady: return "service action dispatcher is unavailable"
            case .offDomain: return "service page is off-domain; refusing to invoke"
            }
        }
    }

    var domain: String { page.url?.host ?? "browser" }

    func owns(_ session: BrowserSession) -> Bool { self === session && isOpen }

    func close(error: any Error) {
        guard isOpen else { return }
        openingTask?.cancel()
        openingTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        page.stopLoading()
        _ = transitionNavigation(.terminated(error), on: self)
        events.close()
        isOpen = false
        manager.actionScheduler.discard(self, error: error)
        userContentController.removeAllScriptMessageHandlers()
        Log.webView.info("BrowserSession.closed session=\(logLabel)")
    }

    func configureScripts(for url: URL?, in session: BrowserSession) {
        let mode: ScriptMode = url?.host.map { host in
            frameServiceSources.keys.contains { host == $0 || host.hasSuffix("." + $0) }
        } == true ? .service : .browser
        guard scriptMode != mode else { return }
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(WKUserScript(source: Self.frameIdentityScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        userContentController.addUserScript(WKUserScript(source: Self.windowOpenScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if events.enabled { userContentController.addUserScript(events.userScript) }
        userContentController.addBridgeUserScripts()
        userContentController.addUserScript(WKUserScript(source: frameServicesScript(self), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for script in additionalUserScripts { userContentController.addUserScript(script) }
        scriptMode = mode
        Log.webView.info("BrowserSession.scripts session=\(logLabel) services=\(frameServiceSources.count) mode=\(mode.rawValue)")
    }

    func setEventRecording(paused: Bool) async {
        guard events.enabled, events.paused != paused else { return }
        events.setPaused(paused)
        scriptMode = nil
        configureScripts(for: page.url, in: self)
        for frame in [nil] + frameTargets.values.compactMap(\.info) {
            _ = try? await evalOnce(self, BrowserEventLog.pauseScript(paused), timeout: 1, frame: frame)
        }
    }

    var logLabel: String { String(id.uuidString.prefix(8)) }
    var isReady: Bool { if case .ready = navigationPhase { true } else { false } }
    var isIdle: Bool {
        guard openingTask == nil, !page.isLoading, secretAttempt == nil,
              pendingEvaluations.isEmpty, activeBrowserOperations.isEmpty,
              manager.actionScheduler.isIdle(self) else { return false }
        switch navigationPhase {
        case .ready, .unavailable: return true
        case .pending, .reserved, .navigating, .settling, .verifying: return false
        }
    }
    func finishEvaluation(_ id: UUID, with result: Result<Any?, any Error>) {
        guard let pending = pendingEvaluations.removeValue(forKey: id) else { return }
        pending.timeout.cancel()
        pending.evaluation.cancel()
        pending.continuation.resume(with: result)
    }

    func interruptEvaluations(with error: any Error) {
        for id in Array(pendingEvaluations.keys) {
            finishEvaluation(id, with: .failure(error))
        }
    }
}

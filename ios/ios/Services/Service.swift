import Foundation
import WebKit
import Observation
import SwiftUI

@MainActor
@Observable
final class Service: NSObject, Identifiable {
    nonisolated let id: String
    nonisolated let domain: String
    nonisolated let url: String
    nonisolated let tintHex: UInt32
    private(set) var definition: ServiceDefinition
    let webService: WebService?
    let iOSService: IOSService?
    let remoteMCPService: RemoteMCPService?

    private(set) var title: String
    private(set) var monogram: String
    private(set) var summary: String

    nonisolated var tint: Color { Color(hex: tintHex) }
    var isWebService: Bool { webService != nil }
    var isIOSService: Bool { iOSService != nil }
    var isMCPService: Bool { remoteMCPService != nil }
    var isLocalService: Bool { definition.repositoryID == ServiceRepository.localID }
    var hasWebRuntime: Bool { webService != nil || iOSService?.hasBrowserRuntime == true }
    var icon: ServiceIcon? { definition.icon }
    var detailCapabilities: ServiceDetailCapabilities {
        if let remoteMCPService { return remoteMCPService.detailCapabilities }
        if let iOSService { return iOSService.detailCapabilities }
        guard let webService else { preconditionFailure("service has no implementation") }
        return webService.detailCapabilities
    }
    var accessAuthorizationTitle: String? { remoteMCPService?.authorizationTitle }

    // MARK: - State

    struct Resolved {
        let actions: String
        let skills: [String: String]
    }

    struct AuthObservation: Equatable {
        enum Value: String {
            case signedIn
            case signedOut
        }

        let value: Value
        let observedAt: Date

        var state: SignInState {
            switch value {
            case .signedIn: .signedIn
            case .signedOut: .signedOut
            }
        }
    }

    enum Auth: Equatable {
        case unknown
        case checking(previous: AuthObservation?)
        case signingIn(previous: AuthObservation?)
        case notRequired
        case authorized
        case authorizationRequired
        case notAuthorized
        case observed(AuthObservation)
        case unavailable(previous: AuthObservation?, error: String)

        var observation: AuthObservation? {
            switch self {
            case .checking(let previous), .signingIn(let previous), .unavailable(let previous, _): previous
            case .observed(let observation): observation
            case .unknown, .notRequired, .authorized, .authorizationRequired, .notAuthorized: nil
            }
        }

        var isSignedIn: Bool { observation?.value == .signedIn }
        var isSignedOut: Bool { observation?.value == .signedOut }
        var isSigningIn: Bool { if case .signingIn = self { true } else { false } }
        var isUnavailable: Bool { if case .unavailable = self { true } else { false } }

        var logLabel: String {
            switch self {
            case .unknown: return "unknown"
            case .checking(let previous): return "checking:\(previous?.value.rawValue ?? "unknown")"
            case .signingIn(let previous): return "signingIn:\(previous?.value.rawValue ?? "unknown")"
            case .notRequired: return "notRequired"
            case .authorized: return "authorized"
            case .authorizationRequired: return "authorizationRequired"
            case .notAuthorized: return "notAuthorized"
            case .observed(let observation): return observation.value.rawValue
            case .unavailable(let previous, _): return "unavailable:\(previous?.value.rawValue ?? "unknown")"
            }
        }
    }

    enum SignInState: String, Encodable {
        case notRequired, signedIn, signedOut, authorized, notAuthorized, unknown

        var isAuthenticated: Bool { self == .signedIn || self == .authorized }
        var requiresAuthentication: Bool { self == .signedOut || self == .notAuthorized }
    }

    enum SignInProbeReason: String {
        case attach
        case chatOpen
        case modelSignIn
        case serviceDetail
        case requireAuth
        case clearWebsiteData
        case debug
    }

    enum CapabilityReason: String {
        case serviceDetail
        case attach
        case inspect
        case invoke
        case debug
    }

    enum CapabilityState: Equatable {
        case unloaded
        case loading
        case ready
        case unavailable(String)

        var logLabel: String {
            switch self {
            case .unloaded: "unloaded"
            case .loading: "loading"
            case .ready: "ready"
            case .unavailable: "unavailable"
            }
        }
    }

    enum InvocationRole: Equatable {
        case standard
        case blockingAction
        case authenticationProbe
        case dangerousBrowserControl

        var isAuthenticationProbe: Bool { self == .authenticationProbe }
        var requiresExclusiveAccess: Bool { self != .standard }
    }

    final class Action {
        let service: Service
        let definition: Manifest.Action
        let baseURL: URL
        let blocking: Bool
        let role: InvocationRole
        let scripts: String

        init(
            service: Service,
            definition: Manifest.Action,
            baseURL: URL,
            role: InvocationRole,
            scripts: String
        ) {
            self.service = service
            self.definition = definition
            self.baseURL = baseURL
            self.blocking = definition.blocking || role.requiresExclusiveAccess
            self.role = self.blocking && role == .standard ? .blockingAction : role
            self.scripts = scripts
        }
    }

    final class AuthenticationWaiter {
        let id: UUID
        let name: String
        var continuation: CheckedContinuation<Void, any Error>?

        init(id: UUID, name: String, continuation: CheckedContinuation<Void, any Error>) {
            self.id = id
            self.name = name
            self.continuation = continuation
        }

        func settle(_ result: Result<Void, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    enum PageReleaseReason: String {
        case memoryWarning = "memory-warning"
    }

    enum AuthSignInSource: String {
        case chatCard
        case chatChip
        case serviceDetail
    }

    struct Snapshot: Encodable {
        let domain: String
        let name: String
        let description: String?
        let signIn: SignInState
        let saved: Bool
        let attached: Bool
        let skills: [Manifest.Skill]
    }

    enum OwnedPageOwner: Equatable {
        case flow(ServiceFlowKind, UUID)
        case inspector(UUID)
        case debug(UUID)
        case browser(UUID)

        var logLabel: String {
            switch self {
            case .flow(let kind, _): "flow:\(kind.rawValue)"
            case .inspector: "inspector"
            case .debug: "debug"
            case .browser: "browser"
            }
        }
    }

    enum InspectionPage {
        case owned(ServiceWebPage)
        case browserSession(ServiceWebPage)

        var page: ServiceWebPage {
            switch self {
            case .owned(let page), .browserSession(let page): page
            }
        }
    }

    struct OwnedPage {
        let page: ServiceWebPage
        let owner: OwnedPageOwner
    }

    @MainActor
    final class ServiceWebPage {
        static let maxConcurrentInvocations = 4

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
            let predecessor: NavigationLease?
            var reservation: CheckedContinuation<Bool, Never>?
            var completion: CheckedContinuation<URL?, Never>?
            var timeoutTask: Task<Void, Never>?

            init(label: String, timeout: TimeInterval, predecessor: NavigationLease? = nil) {
                self.label = label
                self.timeout = timeout
                self.predecessor = predecessor
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
                predecessor?.settleCompletion(url)
            }

            func originates(from lease: NavigationLease) -> Bool {
                self === lease || predecessor?.originates(from: lease) == true
            }
        }

        final class NavigationLoad {
            let lease: NavigationLease?
            var generation: Int
            var expectedURL: URL?
            var started = false
            var committed = false

            init(lease: NavigationLease?, generation: Int, expectedURL: URL? = nil) {
                self.lease = lease
                self.generation = generation
                self.expectedURL = expectedURL
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
        let page: WebPage
        let navigationDecider: NavigationDecider
        let userContentController: WKUserContentController
        let actions: String
        var additionalUserScripts: [WKUserScript] = []
        var navigationTask: Task<Void, Never>?
        var navigationGeneration = 0
        var finishedNavigationGeneration = 0
        var navigationStartedAt: Date?
        var navigationPhase: NavigationPhase = .unavailable("new")
        var pendingEvaluations: [UUID: PendingEvaluation] = [:]
        var scriptMode: ScriptMode?

        init(page: WebPage, navigationDecider: NavigationDecider, userContentController: WKUserContentController, actions: String) {
            self.page = page
            self.navigationDecider = navigationDecider
            self.userContentController = userContentController
            self.actions = actions
        }

        var logLabel: String { String(id.uuidString.prefix(8)) }
        var isReady: Bool { if case .ready = navigationPhase { true } else { false } }
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

    enum ResolutionState {
        case idle(Resolved?)
        case resolving(UUID, Task<Void, Never>)

        var resolved: Resolved? {
            switch self {
            case .idle(let r): return r
            case .resolving: return nil
            }
        }

        var logLabel: String {
            switch self {
            case .idle: return "idle"
            case .resolving: return "resolving"
            }
        }
    }

    private(set) var auth: Auth = .unknown
    private(set) var capabilityState: CapabilityState = .unloaded
    @ObservationIgnored var authenticationWaiters: [AuthenticationWaiter] = []
    @ObservationIgnored var authProbeTask: Task<Void, Never>?
    @ObservationIgnored var silentSignInTask: Task<Void, Never>?
    @ObservationIgnored var ownedPages: [ObjectIdentifier: OwnedPage] = [:]
    @ObservationIgnored var attemptedSilentSignIn = false
    @ObservationIgnored private var capabilityTask: Task<Void, Never>?
    #if targetEnvironment(simulator)
    @ObservationIgnored var debugSession: ServiceDebugSession?
    #endif
    @ObservationIgnored unowned let manager: ServiceManager

    var resolutionState: ResolutionState {
        get {
            if let webService { return webService.state }
            guard let browserState = iOSService?.browserState else {
                preconditionFailure("service has no web runtime")
            }
            return browserState
        }
        set {
            if let webService {
                webService.state = newValue
                return
            }
            guard iOSService?.browserState != nil else {
                preconditionFailure("service has no web runtime")
            }
            iOSService?.browserState = newValue
        }
    }

    var servicePages: [ServiceWebPage] {
        manager.actionScheduler.pages(for: self) + ownedPages.values.map(\.page)
    }

    var pages: [WebPage] { servicePages.map(\.page) }

    func owns(_ page: ServiceWebPage) -> Bool {
        servicePages.contains { $0 === page }
    }

    func pageKind(for page: ServiceWebPage) -> String {
        ownedPages[ObjectIdentifier(page)]?.owner.logLabel ?? "pooled"
    }

    var pageCount: Int { pages.count }

    var manifest: JSONValue? { definition.manifest }

    var skills: [Manifest.Skill] { definition.skills }
    var supportsBotControl: Bool { definition.supportsBotControl }

    func skill(named name: String) -> String? {
        hasWebRuntime ? resolutionState.resolved?.skills[name] : nil
    }

    func actionLabel(for id: String) -> String? {
        definition.action(id, includingStandard: true)?.label
    }

    func resolvedAction(
        _ id: String,
        args: JSONValue = .object([:]),
        role: InvocationRole = .standard
    ) async -> Action? {
        await loadManifest()
        guard let definition = definition.action(id, includingStandard: true),
              let baseURL = definition.resolvedBaseURL(for: args),
              let scripts = resolutionState.resolved?.actions else { return nil }
        return Action(service: self, definition: definition, baseURL: baseURL, role: role, scripts: scripts)
    }

    func inspectionAction() async -> Action? {
        await loadManifest()
        guard let baseURL = definition.baseURL,
              let scripts = resolutionState.resolved?.actions,
              let definition = Manifest.Action(
                .object([
                    "id": .string("inspect"),
                    "blocking": .bool(true),
                    "inputSchema": .object([:]),
                    "outputSchema": .object([:]),
                ]),
                serviceDomain: domain == "ios:browser" ? nil : domain,
                serviceBaseURL: baseURL
              ) else { return nil }
        return Action(service: self, definition: definition, baseURL: baseURL, role: .blockingAction, scripts: scripts)
    }

    var page: WebPage? { pages.first }
    var signInState: SignInState {
        switch auth {
        case .notRequired: .notRequired
        case .authorized: .authorized
        case .authorizationRequired, .notAuthorized: .notAuthorized
        case .observed(let observation): observation.state
        case .signingIn(let previous): previous?.state ?? .unknown
        case .unknown, .checking, .unavailable: .unknown
        }
    }

    func snapshot(attached: Bool) -> Snapshot {
        Snapshot(
            domain: domain,
            name: title,
            description: summary.isEmpty ? nil : summary,
            signIn: signInState,
            saved: manager.isSaved(self),
            attached: attached,
            skills: skills
        )
    }

    init(
        definition: ServiceDefinition,
        monogram: String,
        tint: UInt32,
        manager: ServiceManager
    ) {
        self.id = definition.domain
        self.title = definition.name
        self.domain = definition.domain
        self.url = definition.baseURL?.absoluteString ?? ""
        self.monogram = monogram
        self.tintHex = tint
        self.summary = definition.description
        self.definition = definition
        let implementations = Self.makeImplementations(for: definition)
        self.webService = implementations.web
        self.iOSService = implementations.iOS
        self.remoteMCPService = implementations.remoteMCP
        self.manager = manager
        super.init()
        if definition.isIOS {
            auth = iOSService?.requiresPermission == true ? .unknown : .notRequired
            capabilityState = .ready
        } else if definition.isMCP {
            auth = .unknown
            capabilityState = definition.actions.isEmpty ? .unloaded : .ready
        }
    }

    nonisolated override func isEqual(_ object: Any?) -> Bool {
        (object as? Service)?.id == id
    }
    nonisolated override var hash: Int { id.hashValue }

    private static func makeImplementations(
        for definition: ServiceDefinition
    ) -> (web: WebService?, iOS: IOSService?, remoteMCP: RemoteMCPService?) {
        if let endpoint = definition.mcpEndpoint {
            return (nil, nil, RemoteMCPService(endpoint: endpoint, transport: definition.mcpTransport))
        }
        if definition.isIOS {
            return (nil, IOSService(domain: definition.domain, permission: definition.iOSPermission), nil)
        }
        return (WebService(), nil, nil)
    }

    // MARK: - State mutators

    func setAuth(_ next: Auth) {
        guard auth != next else { return }
        let previous = auth
        auth = next
        Log.service.info("Service.auth domain=\(domain) -> \(next.logLabel) from=\(previous.logLabel) pages=\(pageCount)")
        if !next.isSigningIn { releaseAuthenticationWaiters() }
        for page in servicePages { advancePage(page) }
    }

    // MARK: - Tier 1: manifest

    @discardableResult
    func loadManifest(reason: CapabilityReason = .inspect) async -> JSONValue? {
        if let mcp = remoteMCPService {
            await loadMCPCapabilities(mcp, reason: reason)
            return capabilityState == .ready ? definition.manifest : nil
        }
        guard hasWebRuntime else { return definition.manifest }
        if resolutionState.resolved != nil { return definition.manifest }
        if case .resolving(_, let task) = resolutionState {
            await task.value
            return resolutionState.resolved == nil ? nil : definition.manifest
        }
        setCapabilityState(.loading, reason: reason)
        let resolutionID = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            guard let fetched = await self.manager.fetch(domain: self.domain) else {
                Log.service.error("Service.loadManifest resolve failed domain=\(self.domain)")
                guard self.finishManifestResolution(resolutionID, with: nil) else { return }
                self.setCapabilityState(.unavailable("service files are unavailable"), reason: reason)
                return
            }
            let resolved = Resolved(actions: fetched.actions, skills: fetched.skills)
            if self.finishManifestResolution(resolutionID, with: resolved) {
                self.setCapabilityState(.ready, reason: reason)
                Log.service.info("Service.loadManifest resolved domain=\(self.domain)")
            }
        }
        guard case .idle(nil) = resolutionState else {
            task.cancel()
            return resolutionState.resolved == nil ? nil : definition.manifest
        }
        resolutionState = .resolving(resolutionID, task)
        await task.value
        return resolutionState.resolved == nil ? nil : definition.manifest
    }

    private func finishManifestResolution(_ id: UUID, with resolved: Resolved?) -> Bool {
        guard case .resolving(let current, _) = resolutionState,
              current == id else { return false }
        resolutionState = .idle(resolved)
        return true
    }

    private func loadMCPCapabilities(_ mcp: RemoteMCPService, reason: CapabilityReason) async {
        if capabilityState == .ready { return }
        if let capabilityTask {
            Log.service.info("Service.capabilities joined domain=\(domain) reason=\(reason.rawValue)")
            await capabilityTask.value
            return
        }
        setCapabilityState(.loading, reason: reason)
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            do {
                let descriptor = try await mcp.resolve()
                let resolved = ServiceDefinition(mcp: descriptor, metadata: self.definition)
                self.applyResolvedDefinition(resolved, reason: reason)
            } catch RemoteMCPError.authorizationRequired {
                self.setAuth(.authorizationRequired)
                self.setCapabilityState(.unavailable("authorization is required"), reason: reason)
            } catch {
                self.setCapabilityState(.unavailable(error.localizedDescription), reason: reason)
                Log.service.error("Service.capabilities failed domain=\(self.domain) reason=\(reason.rawValue) error=\(LogPrivacy.text(error.localizedDescription))")
            }
        }
        capabilityTask = task
        await task.value
        capabilityTask = nil
    }

    func applyResolvedDefinition(_ resolved: ServiceDefinition, reason: CapabilityReason) {
        definition = resolved
        title = resolved.name
        summary = resolved.description
        if let mcp = remoteMCPService {
            setAuth(mcp.requiresAuthorization ? (mcp.isAuthorized ? .authorized : .authorizationRequired) : .notRequired)
        }
        setCapabilityState(.ready, reason: reason)
        manager.serviceCapabilitiesDidChange(self)
    }

    private func setCapabilityState(_ next: CapabilityState, reason: CapabilityReason) {
        guard capabilityState != next else { return }
        let previous = capabilityState
        capabilityState = next
        Log.service.info("Service.capabilities domain=\(domain) -> \(next.logLabel) from=\(previous.logLabel) reason=\(reason.rawValue)")
    }

    func makeServiceWebPage(actions: String) -> ServiceWebPage {
        var config = manager.makeServicePageConfiguration(for: domain)
        let ucc = WKUserContentController()
        config.userContentController = ucc
        ucc.installBridgeHandlers(self)
        let navigationDecider = ServiceWebPage.NavigationDecider(service: self)
        let page = WebPage(configuration: config, navigationDecider: navigationDecider)
        let servicePage = ServiceWebPage(
            page: page,
            navigationDecider: navigationDecider,
            userContentController: ucc,
            actions: actions
        )
        navigationDecider.servicePage = servicePage
        Log.webView.info("Service.makePage domain=\(self.domain) contentMode=desktop ua=system")
        #if targetEnvironment(simulator)
        page.isInspectable = true
        #endif
        return servicePage
    }

    func loadServiceWebPage(_ servicePage: ServiceWebPage, at baseURL: URL, label: String) async -> Bool {
        configureScripts(for: baseURL, in: servicePage)
        servicePage.navigationTask = observeNavigations(in: servicePage)
        Log.webView.info("Service.webPage load domain=\(domain) session=\(servicePage.logLabel) label=\(label) url=\(LogPrivacy.url(baseURL.absoluteString)) pages=\(pageCount)")
        let landed = await performNavigation(
            .load(URLRequest(url: baseURL)),
            in: servicePage,
            label: label,
            timeout: 15
        )
        guard landed != nil, owns(servicePage), servicePage.isReady else { return false }
        return true
    }

    func openOwnedPage(for action: Action, owner: OwnedPageOwner) async throws -> ServiceWebPage {
        let page = makeServiceWebPage(actions: action.scripts)
        ownedPages[ObjectIdentifier(page)] = OwnedPage(page: page, owner: owner)
        let loaded = await loadServiceWebPage(
            page,
            at: action.baseURL,
            label: "owned:\(owner.logLabel):\(domain):\(action.definition.id)"
        )
        guard loaded else {
            closeOwnedPage(page, error: EvalError.notReady)
            throw EvalError.notReady
        }
        Log.webView.info("Service.ownedPage event=open owner=\(owner.logLabel) domain=\(domain) session=\(page.logLabel) resident=\(ownedPages.count)")
        return page
    }

    func openInspectionPage(browserSessionID: UUID? = nil) async throws -> InspectionPage {
        guard let action = await inspectionAction() else { throw EvalError.notActive }
        if domain == "ios:browser" {
            guard let browserSessionID,
                  let session = manager.browserActionSessions.existingSession(for: browserSessionID, service: self) else {
                throw EvalError.notActive
            }
            return .browserSession(try await session.inspectionPage())
        }
        let id = UUID()
        return .owned(try await openOwnedPage(for: action, owner: .inspector(id)))
    }

    func closeInspectionPage(_ inspectionPage: InspectionPage) {
        guard case .owned(let page) = inspectionPage else { return }
        closeOwnedPage(page)
    }

    func closeOwnedPage(_ page: ServiceWebPage, error: any Error = CancellationError()) {
        guard let owned = ownedPages.removeValue(forKey: ObjectIdentifier(page)) else { return }
        manager.actionScheduler.discard(page, error: error)
        closeServiceWebPage(page, error: error)
        Log.webView.info("Service.ownedPage event=close owner=\(owned.owner.logLabel) domain=\(domain) session=\(page.logLabel) resident=\(ownedPages.count)")
    }

    private func closeOwnedPages(error: any Error) {
        let pages = ownedPages.values.map(\.page)
        for page in pages { closeOwnedPage(page, error: error) }
    }

    func configureScripts(for url: URL?, in servicePage: ServiceWebPage) {
        let mode: ServiceWebPage.ScriptMode = url?.host.map(isServiceHost) == true ? .service : .browser
        guard servicePage.scriptMode != mode else { return }
        let ucc = servicePage.userContentController
        ucc.removeAllUserScripts()
        if mode == .service {
            ucc.addBridgeUserScripts()
            ucc.addUserScript(WKUserScript(
                source: servicePage.actions,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        for script in servicePage.additionalUserScripts {
            ucc.addUserScript(script)
        }
        servicePage.scriptMode = mode
        Log.webView.info("Service.scripts domain=\(domain) session=\(servicePage.logLabel) mode=\(mode.rawValue)")
    }

    func invalidateResolved() {
        guard webService != nil else { return }
        manager.sessionCoordinator.cancel(for: self)
        #if targetEnvironment(simulator)
        debugSession?.close()
        debugSession = nil
        #endif
        closeOwnedPages(error: EvalError.contextInvalidated)
        manager.actionScheduler.invalidate(self)
        switch resolutionState {
        case .idle:
            break
        case .resolving(_, let task):
            task.cancel()
        }
        resolutionState = .idle(nil)
        capabilityState = .unloaded
    }

    func discardPages() {
        manager.sessionCoordinator.cancel(for: self)
        #if targetEnvironment(simulator)
        debugSession?.close()
        debugSession = nil
        #endif
        closeOwnedPages(error: CancellationError())
        manager.actionScheduler.discardPages(for: self)
    }

    func resetMCPCapabilities() {
        guard let endpoint = definition.mcpEndpoint else { return }
        capabilityTask?.cancel()
        capabilityTask = nil
        definition = ServiceDefinition(
            mcpEndpoint: endpoint,
            transport: definition.mcpTransport,
            name: title,
            description: summary
        )
        capabilityState = .unloaded
        setAuth(.unknown)
        manager.serviceCapabilitiesDidChange(self)
    }

    private func closePage(_ page: ServiceWebPage, error: any Error) {
        page.navigationTask?.cancel()
        page.navigationTask = nil
        page.page.stopLoading()
        transitionNavigation(.terminated(error), on: page)
    }

    func closeServiceWebPage(_ servicePage: ServiceWebPage, error: any Error = CancellationError()) {
        closePage(servicePage, error: error)
    }

    // MARK: - Browser

    enum NavigationCommand {
        case load(URLRequest)
        case reload
        case back
        case forward
    }

    enum InvokeError: LocalizedError {
        case denied(String)
        case unknown(String)
        case requiresAuth(String)
        case authUnavailable(String)
        case invalidContract(String)
        case invalidInput(String, [JSONSchemaValidator.Violation])
        case invalidOutput(String, [JSONSchemaValidator.Violation])

        static func describe(_ violations: [JSONSchemaValidator.Violation]) -> String {
            violations.map { "\($0.path) \($0.message)" }.joined(separator: "; ")
        }

        var errorDescription: String? {
            switch self {
            case .denied(let name): return "action \"\(name)\" denied by user"
            case .unknown(let name): return "unknown action \"\(name)\""
            case .requiresAuth(let name): return "action \"\(name)\" requires sign-in — the user is not signed in to this service. Ask them to sign in, then retry."
            case .authUnavailable(let name): return "action \"\(name)\" could not verify the service sign-in state. Retry after the service is available."
            case .invalidContract(let name): return "action \"\(name)\" has an invalid manifest contract"
            case .invalidInput(let name, let violations): return "action \"\(name)\" input is invalid: \(Self.describe(violations))"
            case .invalidOutput(let name, let violations): return "action \"\(name)\" returned invalid output: \(Self.describe(violations))"
            }
        }
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
}

extension Service {
    private static let brandedTints: [String: UInt32] = [
        "ios:browser": 0x007AFF,
    ]

    convenience init(definition: ServiceDefinition, manager: ServiceManager) {
        let monogram = String(definition.name.unicodeScalars.first.map { String(Character($0)) }?.uppercased() ?? "?")
        self.init(
            definition: definition,
            monogram: monogram,
            tint: Service.brandedTints[definition.domain] ?? Service.tintFor(seed: definition.domain),
            manager: manager
        )
    }

    func relocalize(from definition: ServiceDefinition) {
        guard definition.domain == domain else {
            Log.service.error("Service.relocalize domain-mismatch actual=\(definition.domain) expected=\(domain)")
            return
        }
        guard definition.isIOS == isIOSService, definition.isMCP == isMCPService else {
            Log.service.error("Service.relocalize backend-mismatch domain=\(domain) iOS=\(definition.isIOS) mcp=\(definition.isMCP)")
            return
        }
        let localized = if definition.isMCP,
                           definition.actions.isEmpty,
                           let descriptor = remoteMCPService?.descriptor {
            ServiceDefinition(mcp: descriptor, metadata: definition)
        } else {
            definition
        }
        self.definition = localized
        title = localized.name
        monogram = String(localized.name.unicodeScalars.first.map { String(Character($0)) }?.uppercased() ?? "?")
        summary = localized.description
        Log.service.info("Service.relocalize domain=\(domain) title=\(localized.name)")
    }

    private static func tintFor(seed: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for b in seed.utf8 { h = (h ^ UInt32(b)) &* 0x01000193 }
        let r = 0x40 &+ (h & 0x7f)
        let g = 0x40 &+ ((h >> 8) & 0x7f)
        let b = 0x40 &+ ((h >> 16) & 0x7f)
        return (r << 16) | (g << 8) | b
    }
}

nonisolated extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

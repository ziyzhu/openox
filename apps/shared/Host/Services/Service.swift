import Foundation
import CryptoKit
import WebKit
import Observation

@MainActor
@Observable
final class Service: NSObject, Identifiable {
    nonisolated let id: String
    nonisolated let domain: String
    nonisolated let url: String
    nonisolated let tintHex: UInt32
    private(set) var definition: ServiceDefinition
    @ObservationIgnored var sourceVersion: String?
    let webService: WebService?
    let iOSService: IOSService?
    let remoteMCPService: RemoteMCPService?
    private(set) var apiService: APIService?

    var title: String { manager.serviceNames[domain] ?? definition.name }
    private(set) var summary: String

    var isWebService: Bool { webService != nil }
    var isIOSService: Bool { iOSService != nil }
    var isAPIService: Bool { apiService != nil }
    var isMCPService: Bool { remoteMCPService != nil }
    var isLocalService: Bool { definition.repositoryID == Repository.localID }
    var hasWebRuntime: Bool { webService != nil || iOSService?.hasBrowserRuntime == true }
    var icon: ServiceIcon? { definition.icon }
    var detailCapabilities: ServiceDetailCapabilities {
        if let apiService { return apiService.detailCapabilities }
        if let remoteMCPService { return remoteMCPService.detailCapabilities }
        if let iOSService { return iOSService.detailCapabilities }
        guard let webService else { preconditionFailure("service has no implementation") }
        return webService.detailCapabilities
    }
    var accessAuthorizationTitle: String? { remoteMCPService?.authorizationTitle }

    // MARK: - State

    struct Resolved {
        let actions: String
    }

    struct AuthObservation: Equatable {
        enum Value: String {
            case signedIn
            case signedOut
        }

        enum Evidence {
            case verified
            case configured
        }

        let value: Value
        let observedAt: Date
        let evidence: Evidence

        init(value: Value, observedAt: Date, evidence: Evidence = .verified) {
            self.value = value
            self.observedAt = observedAt
            self.evidence = evidence
        }

        var state: LoginState {
            switch value {
            case .signedIn: .signedIn
            case .signedOut: .signedOut
            }
        }
    }

    enum Auth: Equatable {
        case unknown
        case checking(previous: AuthObservation?)
        case loggingIn(previous: AuthObservation?)
        case notRequired
        case authorized
        case authorizationRequired
        case notAuthorized
        case observed(AuthObservation)
        case unavailable(previous: AuthObservation?, error: String)

        var observation: AuthObservation? {
            switch self {
            case .checking(let previous), .loggingIn(let previous), .unavailable(let previous, _): previous
            case .observed(let observation): observation
            case .unknown, .notRequired, .authorized, .authorizationRequired, .notAuthorized: nil
            }
        }

        var isSignedIn: Bool { observation?.value == .signedIn }
        var isSignedOut: Bool { observation?.value == .signedOut }
        var isChecking: Bool { if case .checking = self { true } else { false } }
        var isLoggingIn: Bool { if case .loggingIn = self { true } else { false } }
        var isUnavailable: Bool { if case .unavailable = self { true } else { false } }

        var logLabel: String {
            switch self {
            case .unknown: return "unknown"
            case .checking(let previous): return "checking:\(previous?.value.rawValue ?? "unknown")"
            case .loggingIn(let previous): return "loggingIn:\(previous?.value.rawValue ?? "unknown")"
            case .notRequired: return "notRequired"
            case .authorized: return "authorized"
            case .authorizationRequired: return "authorizationRequired"
            case .notAuthorized: return "notAuthorized"
            case .observed(let observation): return observation.evidence == .configured ? "configured:\(observation.value.rawValue)" : observation.value.rawValue
            case .unavailable(let previous, _): return "unavailable:\(previous?.value.rawValue ?? "unknown")"
            }
        }
    }

    enum LoginState: String, Encodable {
        case notRequired, signedIn, signedOut, authorized, notAuthorized, unknown

        var isAuthenticated: Bool { self == .signedIn || self == .authorized }
        var requiresAuthentication: Bool { self == .signedOut || self == .notAuthorized }
    }

    enum AccessPolicy: String {
        case cached
        case current
    }

    enum LoginProbeReason: String {
        case attach
        case conversationOpen
        case modelLogin
        case pendingLogin
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
        case dangerousBrowserControl
        case conversation

        var requiresExclusiveAccess: Bool { self != .standard && self != .conversation }
    }

    final class Action {
        let service: Service
        let definition: Manifest.Action
        let baseURL: URL
        let blocking: Bool
        let role: InvocationRole
        let scripts: String
        let session: JSONValue?
        let scopeID: UUID?

        init(
            service: Service,
            definition: Manifest.Action,
            baseURL: URL,
            role: InvocationRole,
            scripts: String,
            session: JSONValue? = nil,
            scopeID: UUID? = nil
        ) {
            self.service = service
            self.definition = definition
            self.baseURL = baseURL
            self.blocking = definition.blocking || role.requiresExclusiveAccess
            self.role = self.blocking && role == .standard ? .blockingAction : role
            self.scripts = scripts
            self.session = session
            self.scopeID = scopeID
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

    enum AuthLoginSource: String {
        case conversationCard
        case canvas
        case conversationChip
        case serviceDetail
    }

    struct Snapshot: Encodable {
        let domain: String
        let name: String
        let description: String?
        let login: LoginState
        let saved: Bool
        let attached: Bool
    }

    enum InspectionPage {
        case owned(BrowserSession)
        case browserSession(BrowserSession)

        var page: BrowserSession {
            switch self {
            case .owned(let page), .browserSession(let page): page
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
    var conversationHandoffs: [UUID: (ownerID: UUID, session: ServiceHandoffSession)] = [:]

    func isHandoffActive(pageID: UUID) -> Bool {
        switch conversationHandoffs[pageID]?.session.phase {
        case .ready, .running: true
        case .completed, .cancelled, .failed, nil: false
        }
    }
    @ObservationIgnored var authenticationWaiters: [AuthenticationWaiter] = []
    @ObservationIgnored let access = ServiceAccess()
    var registeredPages: [ObjectIdentifier: BrowserSessionStore.Registration] { manager.browserSessions.pages(for: domain) }
    @ObservationIgnored private var invalidationTask: Task<Void, Never>?
    @ObservationIgnored private var capabilityTask: Task<Void, Never>?
    @ObservationIgnored var debugSession: ServiceDebugSession?
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

    var servicePages: [BrowserSession] {
        registeredPages.values.map(\.page)
    }

    var pages: [WebPage] { servicePages.map(\.page) }

    func servicePage(id: UUID) -> BrowserSession? {
        registeredPages.values.first { $0.page.id == id }?.page
    }

    func owns(_ page: BrowserSession) -> Bool {
        manager.browserSessions.contains(page)
    }

    func pageKind(for page: BrowserSession) -> String {
        registeredPages[ObjectIdentifier(page)]?.owner.logLabel ?? "closed"
    }

    var pageCount: Int { pages.count }

    var manifest: JSONValue? { definition.manifest }


    func actionLabel(for id: String) -> String? {
        definition.action(id, includingStandard: true)?.label
    }

    func resolvedAction(
        _ id: String,
        args: JSONValue = .object([:]),
        role: InvocationRole = .standard,
        session: JSONValue? = nil,
        pageURL: String? = nil,
        scopeID: UUID? = nil
    ) async -> Action? {
        await loadManifest()
        guard let definition = definition.action(id, includingStandard: true),
              let baseURL = definition.resolvedBaseURL(for: args),
              let scripts = resolutionState.resolved?.actions else { return nil }
        let destination: URL
        do {
            destination = try executionURL(defaultURL: baseURL, session: session, pageURL: pageURL)
        } catch { return nil }
        return Action(service: self, definition: definition, baseURL: destination, role: role, scripts: scripts, session: session, scopeID: scopeID)
    }

    func inspectionAction() async -> Action? {
        await loadManifest()
        guard let baseURL = definition.baseURL,
              let scripts = resolutionState.resolved?.actions,
              let definition = Manifest.Action(
                .object([
                    "id": .string("showPage"),
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
    var loginState: LoginState {
        switch auth {
        case .notRequired: .notRequired
        case .authorized: .authorized
        case .authorizationRequired, .notAuthorized: .notAuthorized
        case .observed(let observation): observation.state
        case .loggingIn(let previous): previous?.state ?? .unknown
        case .unknown, .checking, .unavailable: .unknown
        }
    }

    func snapshot(attached: Bool) -> Snapshot {
        Snapshot(
            domain: domain,
            name: title,
            description: summary.isEmpty ? nil : summary,
            login: loginState,
            saved: manager.isSaved(self),
            attached: attached
        )
    }

    init(
        definition: ServiceDefinition,
        tint: UInt32,
        manager: ServiceManager
    ) {
        self.id = definition.domain
        self.domain = definition.domain
        self.url = definition.baseURL?.absoluteString ?? ""
        self.tintHex = tint
        self.summary = definition.description
        self.definition = definition
        let implementations = Self.makeImplementations(for: definition)
        self.apiService = definition.isAPI ? try! APIService(definition: definition) : nil
        self.webService = implementations.web
        self.iOSService = implementations.iOS
        self.remoteMCPService = implementations.remoteMCP
        self.manager = manager
        super.init()
        if definition.isAPI {
            if let authorization = apiService?.authorization, authorization.auth.requiresCredentials {
                auth = .unknown
            } else {
                auth = .notRequired
            }
            capabilityState = .ready
        } else if definition.isIOS {
            auth = iOSService?.requiresPermission == true ? .unknown : .notRequired
            capabilityState = .ready
        } else if definition.isMCP {
            auth = .unknown
            capabilityState = definition.actions.isEmpty ? .unloaded : .ready
        }
        access.didUpdate(auth)
    }

    nonisolated override func isEqual(_ object: Any?) -> Bool {
        (object as? Service)?.id == id
    }
    nonisolated override var hash: Int { id.hashValue }

    private static func makeImplementations(
        for definition: ServiceDefinition
    ) -> (web: WebService?, iOS: IOSService?, remoteMCP: RemoteMCPService?) {
        if definition.isAPI { return (nil, nil, nil) }
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
        access.didUpdate(next)
        Log.service.info("Service.auth domain=\(domain) -> \(next.logLabel) from=\(previous.logLabel) pages=\(pageCount)")
        if !next.isLoggingIn { releaseAuthenticationWaiters() }
        for page in servicePages { advancePage(page) }
    }

    // MARK: - Tier 1: manifest

    @discardableResult
    func loadManifest(reason: CapabilityReason = .inspect) async -> JSONValue? {
        if let mcp = remoteMCPService {
            if reason == .attach || reason == .serviceDetail { return definition.manifest }
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
            let resolved = Resolved(actions: fetched.actions)
            if self.finishManifestResolution(resolutionID, with: resolved) {
                self.sourceVersion = fetched.version
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
                try resolved.validateStandardServiceActions()
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
        summary = resolved.description
        if let mcp = remoteMCPService {
            setAuth(mcp.auth)
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

    func sessionPage(for action: Action) -> BrowserSession? {
        manager.browserSessions.sessionPage(for: action)
    }

    func updateSessionPage(_ page: BrowserSession, session: JSONValue?) {
        manager.browserSessions.updateSessionPage(page, domain: domain, session: session)
    }

    func openSessionPage(for action: Action) async throws -> BrowserSession {
        try await openOwnedPage(for: action, owner: .session(action.session?.objectValue?["id"]?.stringValue))
    }

    func openOwnedPage(for action: Action, owner: BrowserSessionStore.Purpose) async throws -> BrowserSession {
        guard invalidationTask == nil else { throw EvalError.contextInvalidated }
        return try await manager.browserSessions.open(for: action, purpose: owner)
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

    func closeOwnedPage(_ page: BrowserSession, error: any Error = CancellationError()) {
        manager.browserSessions.close(page, error: error)
    }

    private func closeOwnedPages(error: any Error) {
        manager.browserSessions.close(using: domain, error: error)
    }

    private func closeOwnedPagesAfterRunning(error: any Error) async {
        await manager.browserSessions.closeWhenIdle(using: domain, error: error)
    }

    func releaseIdleSessionPages(reason: PageReleaseReason) {
        manager.browserSessions.releaseIdlePages(reason: reason.rawValue)
    }

    func invalidateResolved() async {
        if let invalidationTask { await invalidationTask.value; return }
        let task = Task { @MainActor in
            self.sourceVersion = nil
            if let apiService = self.apiService {
                apiService.source = nil
                return
            }
            guard self.webService != nil else { return }
            self.debugSession?.close()
            self.debugSession = nil
            await self.closeOwnedPagesAfterRunning(error: EvalError.contextInvalidated)
            switch self.resolutionState {
            case .idle:
                break
            case .resolving(_, let task):
                task.cancel()
            }
            self.resolutionState = .idle(nil)
            self.capabilityState = .unloaded
        }
        invalidationTask = task
        await task.value
        invalidationTask = nil
    }

    func discardPages() {
        manager.closeWebConversations(service: self)
        debugSession?.close()
        debugSession = nil
        closeOwnedPages(error: CancellationError())
    }

    func resetMCPCapabilities() {
        guard let endpoint = definition.mcpEndpoint else { return }
        capabilityTask?.cancel()
        capabilityTask = nil
        definition = ServiceDefinition(
            mcpEndpoint: endpoint,
            domain: domain,
            transport: definition.mcpTransport,
            name: title,
            description: summary,
            repositoryID: definition.repositoryID,
            faviconURL: definition.faviconURL
        )
        capabilityState = .unloaded
        setAuth(.unknown)
        manager.serviceCapabilitiesDidChange(self)
    }

    // MARK: - Browser

    typealias NavigationCommand = BrowserSession.NavigationCommand

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
            case .requiresAuth(let name): return "action \"\(name)\" requires login — the user is not logged in to this service. Ask them to log in, then retry."
            case .authUnavailable(let name): return "action \"\(name)\" could not verify the service login state. Retry after the service is available."
            case .invalidContract(let name): return "action \"\(name)\" has an invalid manifest contract"
            case .invalidInput(let name, let violations): return "action \"\(name)\" input is invalid: \(Self.describe(violations))"
            case .invalidOutput(let name, let violations): return "action \"\(name)\" returned invalid output: \(Self.describe(violations))"
            }
        }
    }

    typealias EvalError = BrowserSession.EvalError

}

extension Service {
    private static let brandedTints: [String: UInt32] = [
        "ios:browser": 0x007AFF,
    ]

    convenience init(definition: ServiceDefinition, manager: ServiceManager) {
        self.init(
            definition: definition,
            tint: Service.brandedTints[definition.domain] ?? Service.tintFor(seed: definition.domain),
            manager: manager
        )
    }

    convenience init(
        definition: ServiceDefinition,
        actions: String,
        manager: ServiceManager
    ) {
        self.init(definition: definition, manager: manager)
        if let apiService { apiService.source = Resolved(actions: actions) }
        else { resolutionState = .idle(Resolved(actions: actions)) }
        capabilityState = .ready
    }

    func relocalize(from definition: ServiceDefinition, sourceChanged: Bool) {
        guard definition.domain == domain else {
            Log.service.error("Service.relocalize domain-mismatch actual=\(definition.domain) expected=\(domain)")
            return
        }
        guard definition.isAPI == isAPIService, definition.isIOS == isIOSService, definition.isMCP == isMCPService else {
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
        if localized.isAPI {
            if sourceChanged { apiService = try! APIService(definition: localized) }
            else { apiService?.definition = localized }
        }
        self.definition = localized
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

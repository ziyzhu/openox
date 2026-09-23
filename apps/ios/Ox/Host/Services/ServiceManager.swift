import Foundation
import JavaScriptCore
import WebKit
import Observation
import UIKit

@MainActor
@Observable
final class ServiceManager {
    nonisolated struct PersistedRemoteMCP: Codable {
        let endpoint: String
        let transport: RemoteMCPTransport?
    }

    enum RepositoryState: Equatable {
        case idle
        case syncing
        case ready
        case failed(String)
    }

    enum MonoRepositoryState: Equatable {
        case idle
        case loading
        case ready
    }

    private struct ResolvedServices {
        let services: [Service]
        let byDomain: [String: Service]

        init(_ candidates: [Service] = []) {
            var services: [Service] = []
            var indexByDomain: [String: Int] = [:]
            var replacedDomains: [String] = []
            for candidate in candidates {
                if let index = indexByDomain[candidate.domain] {
                    services[index] = candidate
                    replacedDomains.append(candidate.domain)
                } else {
                    indexByDomain[candidate.domain] = services.count
                    services.append(candidate)
                }
            }
            self.services = services
            byDomain = Dictionary(uniqueKeysWithValues: services.map { ($0.domain, $0) })
            assert(byDomain.count == services.count)
            if !replacedDomains.isEmpty {
                Log.service.warning("ServiceManager.resolvedServices deduplicated=\(Set(replacedDomains).sorted().joined(separator: ","))")
            }
        }
    }

    private enum SemanticState {
        case unavailable
        case pending(UInt64, ServiceSearchIndex.SemanticBuild)
        case building(UInt64, Task<Void, Never>)
        case ready(UInt64)
    }

    private var resolvedServices = ResolvedServices()
    var services: [Service] { resolvedServices.services }
    private var byDomain: [String: Service] { resolvedServices.byDomain }
    private(set) var monoRepositoryRevision: UInt64 = 0 {
        didSet { invalidateFavicons() }
    }
    private(set) var faviconRevision: UInt64 = 0
    private let index = ServiceSearchIndex()
    @ObservationIgnored private var faviconData: [String: Data] = [:]
    @ObservationIgnored private var persistedRemoteMCPServers: [PersistedRemoteMCP] = []
    @ObservationIgnored private var monoRepositoryMCPEndpoints: Set<String> = []
    @ObservationIgnored private let repository: ServiceRepository
    @ObservationIgnored private var monoRepository: ServiceRepository.MonoRepository?
    @ObservationIgnored private var monoRepositoryLocale: String?
    @ObservationIgnored private var monoRepositoryGeneration: UInt64 = 0
    @ObservationIgnored private var semanticState: SemanticState = .unavailable
    @ObservationIgnored private var repositoryLoadActive = false
    @ObservationIgnored private var repositoryLoadWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var memoryWarningObserver: NSObjectProtocol?
    @ObservationIgnored let actionScheduler = ServiceActionScheduler(capacity: 5)
    @ObservationIgnored let sessionCoordinator = ServiceSessionCoordinator()
    @ObservationIgnored let browserActionSessions = ServiceBrowserActionSessionCoordinator()
    @ObservationIgnored private var intrinsicBrowserService: Service?
    @ObservationIgnored private let websiteData = ServiceWebsiteDataCoordinator()
    private(set) var repositoryState: RepositoryState = .idle
    private(set) var monoRepositoryState: MonoRepositoryState = .idle
    private(set) var monoRepositoryHash: String?
    private(set) var repositories: [ServiceRepository.Repository] = []
    private(set) var repositoryConflicts: [ServiceRepository.Conflict] = []

    struct ServiceMatch: Identifiable {
        let service: Service
        let matchedActionID: String?
        let matchedAction: String?
        var id: String { service.id }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, web, api, local, iOS, mcp, saved
        var id: String { rawValue }
    }

    private(set) var savedDomains: Set<String> {
        didSet { UserDefaults.standard.set(savedDomains.sorted(), forKey: Self.savedKey) }
    }

    private(set) var actionPolicies: ActionPolicyConfiguration {
        didSet {
            guard let data = try? JSONEncoder().encode(actionPolicies) else {
                Log.service.error("ServiceManager.actionPolicies encode failed")
                return
            }
            UserDefaults.standard.set(data, forKey: Self.actionPoliciesKey)
        }
    }

    @ObservationIgnored private var attachedServiceDomainsByChat: [UUID: Set<String>] = [:]

    nonisolated static let savedKey = "savedServices"
    nonisolated static let actionPoliciesKey = "actionApprovalPolicies"
    nonisolated static let legacyAutoApproveActionsKey = "autoApproveActions"
    nonisolated static let legacyAutoApproveAllKey = "autoApproveAll"
    nonisolated static let remoteMCPKey = "remoteMCPServers"
    func makeHandoffPageConfiguration(for _: String) -> WebPage.Configuration {
        websiteData.makePageConfiguration()
    }

    func makeServicePageConfiguration(for _: String) -> WebPage.Configuration {
        websiteData.makePageConfiguration()
    }

    func makeBrowserPageConfiguration(for _: String) -> WebPage.Configuration {
        websiteData.makePageConfiguration()
    }

    nonisolated static func websiteDataSite(for domain: String) -> String {
        ServiceWebsiteDataCoordinator.site(for: domain)
    }

    func clearWebsiteData(domain: String) async {
        await websiteData.clear(domain: domain, services: services)
    }

    func exportWebsiteData() async throws -> Data {
        try await websiteData.export(services: services)
    }

    func restoreWebsiteData(_ data: Data) async throws {
        try await websiteData.restore(data, services: services)
    }

    func logAuthRetention(domain: String, trigger: String, outcome: String, now: Date = Date()) async {
        await websiteData.logAuthRetention(domain: domain, trigger: trigger, outcome: outcome, now: now)
    }

    func cookies(for url: URL) async -> [HTTPCookie] {
        await websiteData.cookies(for: url, serviceDomains: byDomain.keys)
    }

    nonisolated private static var launchServerURL: URL? {
        #if targetEnvironment(simulator)
        return SimEnv.servicesEndpoint
        #else
        return nil
        #endif
    }

    nonisolated static let defaultServerURL: URL = {
        if let launchServerURL { return launchServerURL }
        return URL(string: "ox://bundled")!
    }()

    var serverURL: URL { Self.defaultServerURL }

    init() {
        repository = ServiceRepository(developmentRemote: Self.launchServerURL)
        savedDomains = Set(UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? [])
        actionPolicies = Self.loadActionPolicies()
        persistedRemoteMCPServers = Self.loadPersistedRemoteMCPServers()
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.actionScheduler.releaseIdle(reason: .memoryWarning)
            }
        }
    }

    private static func loadActionPolicies(defaults: UserDefaults = .standard) -> ActionPolicyConfiguration {
        guard let data = defaults.data(forKey: actionPoliciesKey) else { return ActionPolicyConfiguration() }
        do {
            let configuration = try JSONDecoder().decode(ActionPolicyConfiguration.self, from: data)
            guard configuration.format == ActionPolicyConfiguration.currentFormat else {
                Log.service.error("ServiceManager.actionPolicies unsupported format=\(configuration.format)")
                return ActionPolicyConfiguration(defaultPolicy: .ask)
            }
            return configuration
        } catch {
            Log.service.error("ServiceManager.actionPolicies decode failed error=\(error.localizedDescription)")
            return ActionPolicyConfiguration(defaultPolicy: .ask)
        }
    }

    func prepareStorage() async throws {
        try await repository.prepareStorage()
    }

    func reloadPersistedStorage() {
        persistedRemoteMCPServers = Self.loadPersistedRemoteMCPServers()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    private static func loadPersistedRemoteMCPServers() -> [PersistedRemoteMCP] {
        UserDefaults.standard.data(forKey: remoteMCPKey).flatMap {
            try? JSONDecoder().decode([PersistedRemoteMCP].self, from: $0)
        } ?? []
    }

    // MARK: - Saved services

    var savedServices: [Service] {
        services.filter { savedDomains.contains($0.domain) }
    }

    func isSaved(_ service: Service) -> Bool { savedDomains.contains(service.domain) }

    func setSaved(_ service: Service, _ saved: Bool) {
        guard isSaved(service) != saved else { return }
        if saved {
            savedDomains.insert(service.domain)
        } else {
            savedDomains.remove(service.domain)
        }
        Log.service.info("ServiceManager.setSaved domain=\(service.domain) saved=\(saved)")
    }

    var defaultActionPolicy: ActionPolicy? {
        get { actionPolicies.defaultPolicy }
        set {
            guard actionPolicies.defaultPolicy != newValue else { return }
            actionPolicies.defaultPolicy = newValue
            Log.service.info("ServiceManager.actionPolicy default=\(newValue?.rawValue ?? "automatic")")
        }
    }

    func actionPolicy(for action: String, default actionDefault: ActionPolicy) -> ActionPolicy {
        actionPolicies.policy(for: action, default: actionDefault)
    }

    func defaultPolicy(for action: String) -> ActionPolicy {
        if Actions.builtIn.contains(action) { return Actions.defaultPolicy(for: action) }
        for service in services {
            guard let serviceAction = service.definition.exposedActions.first(where: {
                service.definition.qualifiedActionName($0.id) == action
            }) else { continue }
            return serviceAction.requireApproval ? .ask : .allow
        }
        return .ask
    }

    func explicitActionPolicy(for action: String) -> ActionPolicy? { actionPolicies.actions[action] }

    func setActionPolicy(_ policy: ActionPolicy?, for action: String) {
        guard actionPolicies.actions[action] != policy else { return }
        actionPolicies.actions[action] = policy
        Log.service.info("ServiceManager.actionPolicy action=\(action) policy=\(policy?.rawValue ?? "inherited")")
    }

    func sourcePolicy(for source: String) -> ActionPolicy? { actionPolicies.sources[source] }

    func resolvedSourcePolicy(for source: String) -> ActionPolicy? {
        actionPolicies.sources[source] ?? actionPolicies.defaultPolicy
    }

    func setSourcePolicy(_ policy: ActionPolicy?, for source: String) {
        guard actionPolicies.sources[source] != policy else { return }
        actionPolicies.sources[source] = policy
        Log.service.info("ServiceManager.actionPolicy source=\(source) policy=\(policy?.rawValue ?? "inherited")")
    }

    func service(domain: String) -> Service? { byDomain[domain] }

    var browserService: Service {
        if let intrinsicBrowserService { return intrinsicBrowserService }
        let service = Service(definition: BrowserFunctionCatalog.serviceDefinition, manager: self)
        intrinsicBrowserService = service
        return service
    }

    func inspectionService(domain: String) -> Service? {
        if domain == BrowserFunctionCatalog.publicNamespace || domain == BrowserFunctionCatalog.internalDomain {
            return browserService
        }
        return service(domain: domain)
    }

    func connectRemoteMCP(
        _ rawEndpoint: String,
        transport: RemoteMCPTransport? = nil,
        allowsAuthorization: Bool = true,
        replacing: Service? = nil
    ) async throws -> Service {
        let endpoint = try RemoteMCPService.endpoint(rawEndpoint)
        if let replacing {
            guard replacing.isMCPService,
                  persistedRemoteMCPServers.contains(where: { $0.endpoint == replacing.definition.mcpEndpoint?.absoluteString }),
                  !monoRepositoryMCPEndpoints.contains(replacing.definition.mcpEndpoint?.absoluteString ?? "") else {
                throw RuntimeError.bridge("Only directly connected MCP servers can be updated; repository definitions are read-only.")
            }
            guard !services.contains(where: { $0.definition.mcpEndpoint == endpoint && $0 !== replacing }) else {
                throw RuntimeError.bridge("An MCP service already uses this endpoint.")
            }
        }
        let existing = services.first(where: { $0.definition.mcpEndpoint == endpoint })
        let service = (replacing == nil ? existing : nil)
            ?? Service(
                definition: ServiceDefinition(mcpEndpoint: endpoint, transport: transport),
                manager: self
            )
        if await service.loadManifest(reason: .serviceDetail) == nil,
           service.auth == .authorizationRequired,
           allowsAuthorization {
            try await service.requestAccess()
        }
        guard service.capabilityState == .ready else {
            throw RemoteMCPError.protocolError("Ox could not load this MCP server's tools")
        }
        try Task.checkCancellation()
        if let replacing {
            if replacing.definition.mcpEndpoint != endpoint {
                await removeRemoteMCP(replacing)
            } else {
                await replacing.remoteMCPService?.deactivate()
                clearMCPApprovals(replacing)
                resolvedServices = ResolvedServices(services.filter { $0 !== replacing })
            }
        }
        if byDomain[service.domain] == nil {
            resolvedServices = ResolvedServices(services + [service])
            monoRepositoryRevision &+= 1
            reindexMonoRepository()
        }
        persistedRemoteMCPServers.removeAll { $0.endpoint == endpoint.absoluteString }
        persistedRemoteMCPServers.append(PersistedRemoteMCP(
            endpoint: endpoint.absoluteString,
            transport: service.definition.mcpTransport
        ))
        persistRemoteMCPServers()
        Log.service.info("RemoteMCP.save id=\(service.domain) updated=\(replacing != nil)")
        setSaved(service, true)
        return service
    }

    func removeRemoteMCP(_ service: Service) async {
        guard service.isMCPService, let endpoint = service.definition.mcpEndpoint else { return }
        await service.remoteMCPService?.remove()
        persistedRemoteMCPServers.removeAll { $0.endpoint == endpoint.absoluteString }
        savedDomains.remove(service.domain)
        clearMCPApprovals(service)
        if monoRepositoryMCPEndpoints.contains(endpoint.absoluteString) {
            service.resetMCPCapabilities()
        } else {
            resolvedServices = ResolvedServices(services.filter { $0.domain != service.domain })
        }
        monoRepositoryRevision &+= 1
        persistRemoteMCPServers()
        reindexMonoRepository()
        Log.service.info("RemoteMCP.remove id=\(service.domain) endpoint=\(LogPrivacy.url(service.url))")
    }

    private func clearMCPApprovals(_ service: Service) {
        actionPolicies.actions = actionPolicies.actions.filter {
            !$0.key.hasPrefix("mcp:\(service.domain):") && !$0.key.hasPrefix("\(service.domain):")
        }
        actionPolicies.sources.removeValue(forKey: service.domain)
    }

    // An attached service whose origin owns this URL, so a tapped link can open
    // inside that service's credentialed page instead of a logged-out Safari.
    func attachedService(for url: URL) -> Service? {
        let attachedDomains = attachedServiceDomainsByChat.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        return relatedWebServices(for: url).first { attachedDomains.contains($0.domain) }
    }

    func relatedWebServices(for url: URL) -> [Service] {
        guard let rawHost = url.host?.lowercased() else { return [] }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return services
            .filter { service in
                guard service.webService != nil else { return false }
                let domain = service.domain.lowercased()
                return host == domain || host.hasSuffix("." + domain)
            }
            .sorted { lhs, rhs in
                let lhsDomain = lhs.domain.lowercased()
                let rhsDomain = rhs.domain.lowercased()
                let lhsExact = lhsDomain == host
                let rhsExact = rhsDomain == host
                if lhsExact != rhsExact { return lhsExact }
                let lhsLabels = lhsDomain.split(separator: ".").count
                let rhsLabels = rhsDomain.split(separator: ".").count
                if lhsLabels != rhsLabels { return lhsLabels > rhsLabels }
                return lhsDomain < rhsDomain
            }
    }

    func isAttached(domain: String, to chatID: UUID) -> Bool {
        attachedServiceDomainsByChat[chatID]?.contains(domain) == true
    }

    func setAttachedServices(_ attached: [Service], for chatID: UUID) {
        let previous = attachedServiceDomainsByChat.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        attachedServiceDomainsByChat[chatID] = Set(attached.map(\.domain))
        updateMCPActivation(from: previous)
    }

    func removeAttachedServices(for chatID: UUID) {
        let previous = attachedServiceDomainsByChat.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        attachedServiceDomainsByChat.removeValue(forKey: chatID)
        updateMCPActivation(from: previous)
    }

    private func updateMCPActivation(from previous: Set<String>) {
        let current = attachedServiceDomainsByChat.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for domain in current.subtracting(previous) {
            guard let service = service(domain: domain), let mcp = service.remoteMCPService else { continue }
            Task {
                do {
                    guard await service.loadManifest(reason: .attach) != nil else { return }
                    try await mcp.activate()
                } catch {
                    Log.service.error("RemoteMCP.attach failed id=\(domain) error=\(error.localizedDescription)")
                }
            }
        }
        for domain in previous.subtracting(current) {
            guard let mcp = service(domain: domain)?.remoteMCPService else { continue }
            Task { await mcp.deactivate() }
        }
    }

    func faviconImage(for domain: String, preferredTheme: String? = nil) async -> Data? {
        guard let service = byDomain[domain] else { return nil }
        let revision = faviconRevision
        let cacheKey = service.isMCPService ? "\(domain):\(preferredTheme ?? "any")" : domain
        if let data = faviconData[cacheKey] { return data }
        let data: Data?
        if let url = service.definition.faviconURL {
            data = await ServiceImageLoader.data(url: url)
        } else if service.isMCPService {
            guard let endpoint = service.definition.baseURL else {
                Log.service.error("RemoteMCP.icon missing endpoint id=\(domain)")
                return nil
            }
            data = await ServiceImageLoader.data(
                icons: service.definition.remoteMCPIcons,
                endpoint: endpoint,
                preferredTheme: preferredTheme
            )
        } else {
            Log.service.info("Service.icon missing id=\(domain)")
            return nil
        }
        guard faviconRevision == revision, !Task.isCancelled else { return nil }
        if let data {
            faviconData[cacheKey] = data
            if service.isMCPService && service.definition.faviconURL == nil {
                Log.service.info("RemoteMCP.icon loaded id=\(domain) bytes=\(data.count) theme=\(preferredTheme ?? "any")")
            } else {
                Log.service.info("Service.icon loaded id=\(domain) bytes=\(data.count)")
            }
        }
        return data
    }

    private func invalidateFavicons() {
        faviconData.removeAll()
        faviconRevision &+= 1
        Log.service.info("Service.icon invalidated revision=\(self.faviconRevision)")
    }

    @discardableResult
    func refreshServices(locale: String?) async -> [String] {
        await loadRepositories(locale: locale)
    }

    func prepareServices(domains: [String], locale: String?) async throws -> [Service] {
        try Task.checkCancellation()
        await refreshServices(locale: locale)
        try Task.checkCancellation()
        if case .failed(let message) = repositoryState {
            throw RuntimeError.bridge("Service catalog could not be loaded: \(message)")
        }
        guard monoRepositoryState == .ready else {
            throw RuntimeError.bridge("Service catalog is not ready.")
        }
        var seen: Set<String> = []
        let required = domains.filter { seen.insert($0).inserted }
        let missing = required.filter { service(domain: $0) == nil }
        guard missing.isEmpty else {
            throw RuntimeError.bridge("Required services are unavailable: \(missing.joined(separator: ", "))")
        }
        let resolved = required.compactMap { service(domain: $0) }
        let unavailable = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for service in resolved {
                group.addTask { await service.loadManifest() == nil ? service.domain : nil }
            }
            var unavailable: [String] = []
            for await domain in group {
                if let domain { unavailable.append(domain) }
            }
            return unavailable.sorted()
        }
        try Task.checkCancellation()
        guard unavailable.isEmpty else {
            throw RuntimeError.bridge("Required service capabilities could not be loaded: \(unavailable.joined(separator: ", "))")
        }
        Log.service.info("ServiceManager.prepareServices ready domains=\(required.joined(separator: ","))")
        return resolved
    }

    private func loadRepositories(locale: String?) async -> [String] {
        await acquireRepositoryLoad()
        defer { releaseRepositoryLoad() }
        let before = monoRepositoryHash
        repositoryState = .syncing
        do {
            let monoRepository = try await repository.monoRepository()
            self.monoRepository = monoRepository
            repositories = monoRepository.repositories
            repositoryConflicts = monoRepository.conflicts
            let hasReadyRepository = monoRepository.repositories.contains { repository in
                if case .ready = repository.state { return true }
                return false
            }
            guard hasReadyRepository else {
                let failures = monoRepository.repositories.compactMap {
                    if case .failed(let message) = $0.state { return message }
                    return nil
                }
                throw ServiceRepository.Failure(message: failures.first ?? "No valid service repositories are available")
            }
            monoRepositoryHash = monoRepository.hash
            repositoryState = .ready
            guard before != monoRepository.hash || monoRepositoryState != .ready || monoRepositoryLocale != locale else {
                invalidateFavicons()
                Log.service.info("ServiceManager.refreshServices unchanged monoRepository=\(monoRepository.hash.prefix(12))")
                return []
            }
            let stale = byDomain.values.filter { $0.webService != nil || $0.apiService != nil }
            for service in stale {
                service.invalidateResolved()
            }
            let generation = beginMonoRepositoryUpdate(locale: locale, showLoading: monoRepositoryState != .ready)
            await rebuildMonoRepository(locale: locale, generation: generation)
            Log.service.info("ServiceManager.refreshServices reloaded=\(stale.map(\.domain).sorted()) conflicts=\(monoRepository.conflicts.count)")
            return stale.map(\.domain).sorted()
        } catch {
            repositoryState = .failed(error.localizedDescription)
            Log.service.error("ServiceManager.refreshServices failed=\(error.localizedDescription)")
            return []
        }
    }

    private func acquireRepositoryLoad() async {
        guard repositoryLoadActive else {
            repositoryLoadActive = true
            return
        }
        await withCheckedContinuation { continuation in
            repositoryLoadWaiters.append(continuation)
            Log.service.info("ServiceManager.loadRepositories queued waiters=\(repositoryLoadWaiters.count)")
        }
    }

    private func releaseRepositoryLoad() {
        guard !repositoryLoadWaiters.isEmpty else {
            repositoryLoadActive = false
            return
        }
        repositoryLoadWaiters.removeFirst().resume()
    }

    func changedServiceDomains(since monoRepositoryHash: String) async -> Set<String>? {
        monoRepositoryHash == self.monoRepositoryHash ? [] : nil
    }

    func setRepositoryEnabled(_ repositoryID: String, enabled: Bool, locale: String?) async {
        _ = await mutateRepositories(locale: locale) {
            try await self.repository.setEnabled(repositoryID: repositoryID, enabled: enabled)
        }
    }

    func resolveConflict(serviceID: String, repositoryID: String, locale: String?) async {
        _ = await mutateRepositories(locale: locale) {
            try await self.repository.setResolution(serviceID: serviceID, repositoryID: repositoryID)
        }
    }

    func installRepository(from origin: URL, locale: String?) async {
        _ = await mutateRepositories(locale: locale) {
            try await self.repository.install(from: origin)
        }
    }

    func connectRepository(from origin: URL, locale: String?) async throws -> ServiceRepository.Repository {
        repositoryState = .syncing
        do {
            try await repository.install(from: origin)
            _ = await loadRepositories(locale: locale)
            guard case .ready = repositoryState,
                  let installed = repositories.first(where: { $0.origin == origin }) else {
                throw ServiceRepository.Failure(message: "The repository was installed but could not be loaded")
            }
            return installed
        } catch {
            repositoryState = .failed(error.localizedDescription)
            Log.service.error("ServiceManager.repository connect failed=\(error.localizedDescription)")
            throw error
        }
    }

    @discardableResult
    func updateRepository(_ repositoryID: String, locale: String?) async -> [String] {
        await mutateRepositories(locale: locale) {
            try await self.repository.update(repositoryID: repositoryID)
        }
    }

    func removeRepository(_ repositoryID: String, locale: String?) async {
        _ = await mutateRepositories(locale: locale) {
            try await self.repository.remove(repositoryID: repositoryID)
        }
    }

    func disconnectRepository(_ repositoryID: String, locale: String?) async throws {
        repositoryState = .syncing
        do {
            try await repository.remove(repositoryID: repositoryID)
            _ = await loadRepositories(locale: locale)
            guard case .ready = repositoryState else {
                throw ServiceRepository.Failure(message: "The repository was removed but services could not be reloaded")
            }
        } catch {
            repositoryState = .failed(error.localizedDescription)
            Log.service.error("ServiceManager.repository disconnect failed=\(error.localizedDescription)")
            throw error
        }
    }

    func createService(kind: ServiceRepository.ServiceKind, id: String, locale: String?) async throws {
        try await repository.createService(kind: kind, id: id)
        _ = await loadRepositories(locale: locale)
        guard service(domain: id) != nil else {
            throw ServiceRepository.Failure(message: "The Local service could not be activated.")
        }
    }

    func copyServiceToLocal(domain: String, locale: String?) async throws {
        try await repository.copyServiceToLocal(id: domain)
        _ = await loadRepositories(locale: locale)
        guard monoRepository?.repositories.contains(where: { $0.id == ServiceRepository.localID }) == true else {
            throw ServiceRepository.Failure(message: "The Local repository is unavailable.")
        }
    }

    func exportServicePackage(domain: String) async throws -> Data {
        try await validateService(domain: domain)
        return try await repository.exportLocalService(id: domain)
    }

    func importServicePackage(_ payload: ServicePackagePayload, replacing: Bool, locale: String?) async throws {
        guard let kind = ServicesMount.Kind(rawValue: payload.kind.rawValue) else {
            throw ServicePackageError.invalidPackage
        }
        try await validateServiceSource(kind: kind, domain: payload.domain) { path in
            try payload.read(path.joined(separator: "/"))
        }
        try await repository.importLocalService(payload, replacing: replacing)
        _ = await loadRepositories(locale: locale)
        guard case .ready = repositoryState else {
            throw ServiceRepository.Failure(message: "The service was imported but the repository could not be reloaded.")
        }
    }

    func deleteLocalService(domain: String, locale: String?) async throws -> ServiceRepository.ServiceKind {
        let kind = try await repository.deleteLocalService(id: domain)
        _ = await loadRepositories(locale: locale)
        if service(domain: domain) == nil {
            savedDomains.remove(domain)
            let previous = attachedServiceDomainsByChat.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            for chatID in Array(attachedServiceDomainsByChat.keys) {
                attachedServiceDomainsByChat[chatID]?.remove(domain)
            }
            updateMCPActivation(from: previous)
        }
        return kind
    }

    func serviceGitStatus(repositoryID: String) async throws -> ServiceRepository.GitStatus {
        try await repository.gitStatus(repositoryID: repositoryID)
    }

    func serviceGitLog(repositoryID: String, limit: Int, cursor: String?) async throws -> ServiceRepository.GitLog {
        try await repository.gitLog(repositoryID: repositoryID, limit: limit, cursor: cursor)
    }

    func serviceGitShow(repositoryID: String, commitHash: String, path: String?) async throws -> ServiceRepository.GitShow {
        try await repository.gitShow(repositoryID: repositoryID, commitHash: commitHash, path: path)
    }

    func serviceGitDiff(
        repositoryID: String,
        commitHash: String?,
        baseCommitHash: String?,
        path: String?
    ) async throws -> ServiceRepository.GitDiff {
        try await repository.gitDiff(
            repositoryID: repositoryID,
            commitHash: commitHash,
            baseCommitHash: baseCommitHash,
            path: path
        )
    }

    func checkoutServiceRepository(repositoryID: String, commitHash: String, locale: String?) async throws -> ServiceRepository.GitStatus {
        let status = try await repository.gitCheckout(repositoryID: repositoryID, commitHash: commitHash)
        _ = await loadRepositories(locale: locale)
        return status
    }

    func commitLocalServices(message: String, locale: String?) async throws -> ServiceRepository.GitCommit {
        try await validateLocalRepository()
        let commit = try await repository.gitCommitLocal(message: message)
        _ = await loadRepositories(locale: locale)
        return commit
    }

    func serviceProposalSnapshot(commitHash: String, services: [String]) async throws -> ServiceRepositoryProposalSnapshot {
        let snapshot = try await repository.proposalSnapshot(commitHash: commitHash, services: services)
        for service in snapshot.services {
            guard let kind = ServicesMount.Kind(rawValue: service.kind.rawValue) else {
                throw ServiceRepository.Failure(message: "Only Local web and API services can be published")
            }
            let prefix = "\(service.kind.rawValue)/\(service.domain)/"
            try await validateServiceSource(kind: kind, domain: service.domain) { components in
                let path = prefix + components.joined(separator: "/")
                guard let file = service.files.first(where: { $0.path == path }) else {
                    throw ServiceRepository.Failure(message: "Missing service source file: \(path)")
                }
                return file.data
            }
        }
        return snapshot
    }

    func revertLocalServices(commitHash: String, message: String, locale: String?) async throws -> ServiceRepository.GitCommit {
        try await repository.prepareLocalRevert(commitHash: commitHash)
        do {
            _ = await loadRepositories(locale: locale)
            try await validateLocalRepository()
            let commit = try await repository.commitPreparedLocalRevert(message: message)
            _ = await loadRepositories(locale: locale)
            return commit
        } catch {
            await repository.abortPreparedLocalMutation()
            _ = await loadRepositories(locale: locale)
            throw error
        }
    }

    func restoreLocalServices(path: String?, locale: String?) async throws -> ServiceRepository.GitStatus {
        let status = try await repository.gitRestoreLocal(path: path)
        _ = await loadRepositories(locale: locale)
        return status
    }

    func listServiceSource(kind: ServicesMount.Kind, domain: String, path: [String]) async throws -> [ServiceRepository.Entry] {
        try await repository.listSource(kind: kind.repositoryKind, id: domain, path: path)
    }

    func serviceSourceIsDirectory(kind: ServicesMount.Kind, domain: String, path: [String]) async throws -> Bool {
        try await repository.sourceIsDirectory(kind: kind.repositoryKind, id: domain, path: path)
    }

    func readServiceSource(kind: ServicesMount.Kind, domain: String, path: [String]) async throws -> Data {
        try await repository.readSource(kind: kind.repositoryKind, id: domain, path: path)
    }

    func writeServiceSource(kind: ServicesMount.Kind, domain: String, path: [String], data: Data) async throws {
        try await repository.writeLocalSource(kind: kind.repositoryKind, id: domain, path: path, data: data)
    }

    func deleteServiceSource(kind: ServicesMount.Kind, domain: String, path: [String]) async throws {
        try await repository.deleteLocalSource(kind: kind.repositoryKind, id: domain, path: path)
    }

    func serviceSourcePaths(kind: ServicesMount.Kind, domain: String) async throws -> [String] {
        try await repository.sourcePaths(kind: kind.repositoryKind, id: domain)
    }

    private func localScriptKind(_ domain: String) -> ServicesMount.Kind {
        monoRepository?.repositories.contains(where: {
            $0.id == ServiceRepository.localID && $0.services.contains(where: { $0.id == "api:\(domain)" })
        }) == true ? .api : .web
    }

    func validateService(domain: String) async throws {
        try await validateLocalService(kind: localScriptKind(domain), domain: domain)
        Log.service.info("ServiceManager.validate passed domain=\(domain)")
    }

    private func validateLocalService(kind: ServicesMount.Kind, domain: String) async throws {
        try await repository.validateLocalSource(kind: kind.repositoryKind, id: domain)
        try await validateServiceSource(kind: kind, domain: domain) { path in
            try await self.repository.readLocalSource(kind: kind.repositoryKind, id: domain, path: path)
        }
    }

    private func validateServiceSource(
        kind: ServicesMount.Kind,
        domain: String,
        read: ([String]) async throws -> Data
    ) async throws {
        switch kind {
        case .web, .api:
            let manifestData = try await read(["service.json"])
            let raw = try JSONDecoder().decode(JSONValue.self, from: manifestData)
            let definition = try ServiceDefinition(manifest: raw, repositoryID: ServiceRepository.localID, provenance: .local)
            guard definition.domain == domain, definition.isAPI == (kind == .api) else {
                throw ServiceRepository.Failure(message: "manifest identity does not match its directory")
            }
            let actionsData = try await read(["actions.js"])
            guard let source = String(data: actionsData, encoding: .utf8) else {
                throw ServiceRepository.Failure(message: "actions.js is not UTF-8")
            }
            let context = JSContext()!
            var syntaxError: String?
            context.exceptionHandler = { _, exception in syntaxError = exception?.toString() }
            let encoded = try JSONEncoder().encode(source)
            context.evaluateScript("new Function(\(String(decoding: encoded, as: UTF8.self)))")
            if let syntaxError {
                throw ServiceRepository.Failure(message: "actions.js syntax: \(syntaxError)")
            }
            syntaxError = nil
            context.evaluateScript(#"""
            globalThis.window = globalThis;
            window.ox = {
              __installations: 0,
              __registered: [],
              install(version, installer) {
                this.__installations++;
                if (this.__installations > 1) throw new Error("service installer may run only once");
                if (version !== 1 && version !== 2) throw new Error(`unsupported service action ABI: ${version}`);
                if (typeof installer !== "function") throw new Error("service installer must be a function");
                const names = this.__registered;
                const action = (name, definition) => {
                  if (typeof name !== "string" || !name) throw new Error("action name must be a non-empty string");
                  if (names.includes(name)) throw new Error(`duplicate action: ${name}`);
                  if (typeof definition?.invoke !== "function") throw new Error(`action ${name} has no invoke function`);
                  names.push(name);
                };
                const unavailable = () => { throw new Error("not callable during registration validation"); };
                const legacy = {
                  action,
                  retryFetch: unavailable,
                  request: unavailable,
                  log() {},
                  lib: {
                    cookie: unavailable,
                    cleanText: value => String(value ?? "").replace(/\s+/g, " ").trim(),
                    pageCursor: (value, firstPage) => Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage),
                  },
                };
                const api = version === 1 ? legacy : new Proxy(
                  Object.freeze(\#(kind == .api ? "true" : "false") ? { action, request: unavailable } : { action }),
                  {
                    get(target, name) {
                      if (name in target) return target[name];
                      throw new Error(`service action ABI 2 does not provide ${String(name)}`);
                    },
                  }
                );
                const result = installer(api);
                if (result && typeof result.then === "function") throw new Error("service installer must be synchronous");
              },
            };
            """#)
            context.evaluateScript(source)
            if let syntaxError {
                throw ServiceRepository.Failure(message: "actions.js registration: \(syntaxError)")
            }
            guard let result = context.evaluateScript(
                "JSON.stringify({ installations: window.ox.__installations, actions: window.ox.__registered })"
            )?.toString(),
                  let resultData = result.data(using: .utf8),
                  let registration = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  registration["installations"] as? Int == 1,
                  let registered = registration["actions"] as? [String] else {
                throw ServiceRepository.Failure(message: "actions.js must install exactly once")
            }
            let declared = Set(definition.actions.map(\.id))
            let implemented = Set(registered)
            let missing = declared.subtracting(implemented).sorted()
            let extra = implemented.subtracting(declared).sorted()
            guard missing.isEmpty, extra.isEmpty else {
                let details = [
                    missing.isEmpty ? nil : "missing implementations: \(missing.joined(separator: ", "))",
                    extra.isEmpty ? nil : "undeclared implementations: \(extra.joined(separator: ", "))",
                ].compactMap { $0 }.joined(separator: "; ")
                throw ServiceRepository.Failure(message: "actions.js registration mismatch; \(details)")
            }
            for skill in definition.skills {
                let data = try await read(["skills", skill.name, "SKILL.md"])
                guard let content = String(data: data, encoding: .utf8),
                      SkillFiles.parse(content, directoryName: skill.name) != nil else {
                    throw ServiceRepository.Failure(message: "invalid skill \(skill.name)")
                }
            }
        case .mcp:
            let data = try await read(["service.json"])
            let manifest = try JSONDecoder().decode(MCPCatalogManifest.self, from: data)
            guard manifest.id == domain, manifest.isValid else {
                throw ServiceRepository.Failure(message: "invalid MCP manifest")
            }
        case .iOS:
            throw ServiceRepository.Failure(message: "Native iOS services cannot be edited in Local.")
        }
    }

    private func validateLocalRepository() async throws {
        guard let local = monoRepository?.repositories.first(where: { $0.id == ServiceRepository.localID }) else {
            throw ServiceRepository.Failure(message: "The Local repository is unavailable.")
        }
        for service in local.services {
            guard let separator = service.id.firstIndex(of: ":"),
                  let kind = ServicesMount.Kind(rawValue: String(service.id[..<separator])) else {
                throw ServiceRepository.Failure(message: "Local contains an invalid service identity")
            }
            do {
                try await validateLocalService(kind: kind, domain: service.runtimeID)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw ServiceRepository.Failure(
                    message: "Validation failed for services/\(kind.rawValue)/\(service.runtimeID): \(error.localizedDescription)"
                )
            }
        }
    }

    func serviceForCaller(domain: String, reason: Service.CapabilityReason) async throws -> Service {
        let service = service(domain: domain)
        if let service, !service.isWebService && !service.isAPIService {
            _ = await service.loadManifest(reason: reason)
            return service
        }

        let kind = localScriptKind(domain)
        let definition: ServiceDefinition
        if let service, !service.isLocalService {
            definition = service.definition
        } else {
            try await validateLocalService(kind: kind, domain: domain)
            let manifestData = try await repository.readLocalSource(kind: kind.repositoryKind, id: domain, path: ["service.json"])
            let raw = try JSONDecoder().decode(JSONValue.self, from: manifestData)
            definition = try ServiceDefinition(
                manifest: Manifest.localized(raw, locale: monoRepositoryLocale),
                repositoryID: ServiceRepository.localID,
                provenance: .local
            )
        }

        guard let source = await repository.source(domain: domain, skills: definition.skills.map(\.name)) else {
            throw ServiceRepository.Failure(message: "Service files are unavailable")
        }
        return Service(
            definition: definition,
            actions: source.actions,
            skills: source.skills,
            manager: self
        )
    }

    func selectServiceForAttachment(_ service: Service) {
        guard byDomain[service.domain] !== service else { return }
        let previous = byDomain[service.domain]
        let next = services.contains(where: { $0.domain == service.domain })
            ? services.map { $0.domain == service.domain ? service : $0 }
            : services + [service]
        resolvedServices = ResolvedServices(next)
        monoRepositoryRevision &+= 1
        reindexMonoRepository()
        Log.service.info("ServiceManager.selectServiceForAttachment domain=\(service.domain) from=\(previous?.definition.repositoryID ?? "none") to=\(service.definition.repositoryID ?? "none")")
    }

    private func mutateRepositories(
        locale: String?,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> [String] {
        repositoryState = .syncing
        do {
            try await operation()
            return await loadRepositories(locale: locale)
        } catch {
            repositoryState = .failed(error.localizedDescription)
            Log.service.error("ServiceManager.repository mutation failed=\(error.localizedDescription)")
            return []
        }
    }

    private func rebuildMonoRepository(locale: String?, generation: UInt64) async {
        let listings = await listServices(locale: locale) ?? []
        let iOSDefinitions = await listIOSServiceDefinitions(locale: locale)
        let repositoryMCPDefinitions = await listMCPServiceDefinitions(locale: locale)
        monoRepositoryMCPEndpoints = Set(repositoryMCPDefinitions.compactMap { $0.mcpEndpoint?.absoluteString })
        let localMCPDefinitions = persistedRemoteMCPServers.compactMap { server -> ServiceDefinition? in
            guard !monoRepositoryMCPEndpoints.contains(server.endpoint), let endpoint = URL(string: server.endpoint) else { return nil }
            return ServiceDefinition(mcpEndpoint: endpoint, transport: server.transport)
        }
        let definitions = listings.map(\.definition) + iOSDefinitions + repositoryMCPDefinitions + localMCPDefinitions
        guard monoRepositoryGeneration == generation else {
            Log.service.info("ServiceManager.rebuildMonoRepository superseded generation=\(generation)")
            return
        }
        let next = definitions.compactMap(resolveService)
        let indexedRevision = monoRepositoryRevision
        let semanticBuild = await index.rebuildLexical(from: next.map(\.definition), locale: locale)
        guard monoRepositoryGeneration == generation else {
            Log.service.info("ServiceManager.rebuildMonoRepository superseded-after-index generation=\(generation)")
            return
        }
        let capabilitiesChangedWhileIndexing = monoRepositoryRevision != indexedRevision
        resolvedServices = ResolvedServices(next)
        monoRepositoryRevision &+= 1
        if capabilitiesChangedWhileIndexing {
            semanticState = .unavailable
            reindexMonoRepository()
        } else {
            semanticState = .pending(generation, semanticBuild)
            monoRepositoryState = .ready
        }
        Log.service.info("ServiceManager.rebuildMonoRepository count=\(next.count) locale=\(locale ?? "en") generation=\(generation)")
    }

    private func resolveService(_ definition: ServiceDefinition) -> Service? {
        if let existing = byDomain[definition.domain] {
            existing.relocalize(from: definition)
            return existing
        }
        return Service(definition: definition, manager: self)
    }

    func serviceCapabilitiesDidChange(_ service: Service) {
        guard byDomain[service.domain] === service else { return }
        monoRepositoryRevision &+= 1
        reindexMonoRepository()
    }

    private func reindexMonoRepository() {
        let revision = monoRepositoryRevision
        let definitions = services.map(\.definition)
        let generation = monoRepositoryGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let semanticBuild = await self.index.rebuildLexical(from: definitions, locale: self.monoRepositoryLocale)
            guard self.monoRepositoryRevision == revision, self.monoRepositoryGeneration == generation else { return }
            self.semanticState = .pending(generation, semanticBuild)
            self.monoRepositoryState = .ready
        }
    }

    private func persistRemoteMCPServers() {
        let servers = persistedRemoteMCPServers.sorted { $0.endpoint < $1.endpoint }
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.remoteMCPKey)
        }
    }

    func reloadServices(locale: String?) async {
        guard monoRepository != nil else {
            _ = await loadRepositories(locale: locale)
            return
        }
        guard services.isEmpty || monoRepositoryLocale != locale else { return }
        let generation = beginMonoRepositoryUpdate(locale: locale, showLoading: true)
        for service in byDomain.values { service.invalidateResolved() }
        Log.service.info("ServiceManager.reloadServices count=\(self.byDomain.count) locale=\(locale ?? "en") generation=\(generation)")
        await rebuildMonoRepository(locale: locale, generation: generation)
    }

    private func beginMonoRepositoryUpdate(locale: String?, showLoading: Bool) -> UInt64 {
        if case let .building(_, task) = semanticState { task.cancel() }
        semanticState = .unavailable
        if showLoading { monoRepositoryState = .loading }
        monoRepositoryLocale = locale
        monoRepositoryGeneration &+= 1
        return monoRepositoryGeneration
    }

    func search(_ query: String, filter: Filter) async -> [ServiceMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [ServiceMatch]
        if q.isEmpty {
            base = services.map { ServiceMatch(service: $0, matchedActionID: nil, matchedAction: nil) }
        } else {
            let hits = await index.search(q)
            startSemanticIndexing()
            base = hits.compactMap { hit in
                byDomain[hit.domain].map {
                    ServiceMatch(service: $0, matchedActionID: hit.matchedActionID, matchedAction: hit.matchedAction)
                }
            }
        }
        switch filter {
        case .all: return base
        case .web: return base.filter { $0.service.isWebService }
        case .api: return base.filter { $0.service.isAPIService }
        case .local: return base.filter { $0.service.isLocalService }
        case .iOS: return base.filter { $0.service.isIOSService }
        case .mcp: return base.filter { $0.service.isMCPService }
        case .saved: return base.filter { isSaved($0.service) }
        }
    }

    private func startSemanticIndexing() {
        guard case let .pending(generation, build) = semanticState else { return }
        Log.service.info("ServiceManager.semantic start generation=\(generation) priority=utility")
        let task = Task.detached(priority: .utility) { [weak self] in
            let candidate = await ServiceSearchIndex.buildSemantics(build)
            let cancelled = Task.isCancelled
            await self?.finishSemanticIndexing(candidate, generation: generation, cancelled: cancelled)
        }
        semanticState = .building(generation, task)
    }

    private func finishSemanticIndexing(
        _ candidate: ServiceSearchIndex.SemanticCandidate?,
        generation: UInt64,
        cancelled: Bool
    ) async {
        guard case let .building(activeGeneration, _) = semanticState, activeGeneration == generation else {
            Log.service.info("ServiceManager.semantic discarded generation=\(generation)")
            return
        }
        guard !cancelled, monoRepositoryGeneration == generation else {
            semanticState = .unavailable
            Log.service.info("ServiceManager.semantic cancelled generation=\(generation)")
            return
        }
        guard let candidate else {
            semanticState = .unavailable
            Log.service.info("ServiceManager.semantic unavailable generation=\(generation)")
            return
        }
        let installed = await index.installSemantics(candidate)
        semanticState = installed ? .ready(generation) : .unavailable
        Log.service.info("ServiceManager.semantic finish generation=\(generation) installed=\(installed)")
    }

    nonisolated struct Listing: Sendable {
        let definition: ServiceDefinition
        var domain: String { definition.domain }
    }

    func listServices(locale: String?) async -> [Listing]? {
        guard let files = monoRepository?.webManifests else { return nil }
        let out = await Task.detached(priority: .userInitiated) {
            Self.decodeListings(files, locale: locale)
        }.value
        Log.service.info("ServiceManager.listServices count=\(out.count)")
        return out
    }

    nonisolated private static func decodeListings(
        _ files: [ServiceRepository.ManifestFile],
        locale: String?
    ) -> [Listing] {
        let out: [Listing] = files.compactMap { file in
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: file.data) else { return nil }
            let manifest = Manifest.localized(raw, locale: locale)
            do {
                let definition = try ServiceDefinition(
                    manifest: manifest,
                    repositoryID: file.repositoryID,
                    provenance: file.provenance
                )
                guard definition.domain == file.domain else {
                    Log.service.error("ServiceManager.listServices domain mismatch directory=\(file.domain) manifest=\(definition.domain)")
                    return nil
                }
                return Listing(definition: definition)
            } catch {
                Log.service.error("ServiceManager.listServices invalid domain=\(file.domain) error=\(error.localizedDescription)")
                return nil
            }
        }
        return out
    }

    private func listIOSServiceDefinitions(locale: String?) async -> [ServiceDefinition] {
        guard let files = monoRepository?.iOSManifests else { return [] }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let definitions = files.compactMap { file -> ServiceDefinition? in
            let manifest: IOSCatalogManifest
            do {
                manifest = try JSONDecoder().decode(IOSCatalogManifest.self, from: file.data)
            } catch {
                Log.service.error("ServiceManager.listIOSServices decode id=\(file.id) error=\(error.localizedDescription)")
                return nil
            }
            guard manifest.domain == file.id,
                  manifest.isValid else {
                Log.service.error("ServiceManager.listIOSServices invalid id=\(file.id)")
                return nil
            }
            guard manifest.supports(version) else { return nil }
            do {
                return try ServiceDefinition(
                    iOS: manifest.localized(locale),
                    repositoryID: file.repositoryID
                )
            } catch {
                Log.service.error("ServiceManager.listIOSServices invalid id=\(file.id) error=\(error.localizedDescription)")
                return nil
            }
        }
        Log.service.info("ServiceManager.listIOSServices count=\(definitions.count) os=\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        return definitions
    }

    private func listMCPServiceDefinitions(locale: String?) async -> [ServiceDefinition] {
        guard let files = monoRepository?.mcpManifests else { return [] }
        let definitions = files.compactMap { file -> ServiceDefinition? in
            guard let manifest = try? JSONDecoder().decode(MCPCatalogManifest.self, from: file.data),
                  manifest.id == file.id,
                  manifest.isValid else {
                Log.service.error("ServiceManager.listMCPServices invalid id=\(file.id)")
                return nil
            }
            do {
                return try ServiceDefinition(
                    mcp: manifest.localized(locale),
                    repositoryID: file.repositoryID
                )
            } catch {
                Log.service.error("ServiceManager.listMCPServices invalid id=\(file.id) error=\(error.localizedDescription)")
                return nil
            }
        }
        Log.service.info("ServiceManager.listMCPServices count=\(definitions.count)")
        return definitions
    }

    // MARK: - Fetch

    struct Fetched { let actions: String; let skills: [String: String] }

    // Read the service's built artifacts from the working tree.
    func fetch(domain: String) async -> Fetched? {
        guard let definition = byDomain[domain]?.definition else { return nil }
        if definition.repositoryID == ServiceRepository.localID {
            do {
                try await validateLocalService(kind: localScriptKind(domain), domain: domain)
            } catch {
                Log.service.error("ServiceManager.fetch invalid Local draft domain=\(domain) error=\(error.localizedDescription)")
                return nil
            }
        }
        guard let source = await repository.source(domain: domain, skills: definition.skills.map(\.name)) else {
            Log.service.error("ServiceManager.fetch missing in working tree domain=\(domain)")
            return nil
        }
        Log.service.info("ServiceManager.fetch ok domain=\(domain) actionsBytes=\(source.actions.utf8.count) skills=\(source.skills.count)")
        return Fetched(actions: source.actions, skills: source.skills)
    }

}

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
    private(set) var monoRepositoryRevision: UInt64 = 0
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
        case all, web, local, iOS, mcp, saved
        var id: String { rawValue }
    }

    private(set) var savedDomains: Set<String> {
        didSet { UserDefaults.standard.set(savedDomains.sorted(), forKey: Self.savedKey) }
    }

    private(set) var autoApproveActions: Set<String> {
        didSet { UserDefaults.standard.set(autoApproveActions.sorted(), forKey: Self.autoApproveKey) }
    }

    @ObservationIgnored private var attachedServiceDomainsByChat: [UUID: Set<String>] = [:]

    private static let savedKey = "savedServices"
    private static let autoApproveKey = "autoApproveActions"
    private static let remoteMCPKey = "remoteMCPServers"
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
        autoApproveActions = Set(UserDefaults.standard.stringArray(forKey: Self.autoApproveKey) ?? [])
        persistedRemoteMCPServers = ProfileMigrator.migrateRemoteMCPServers(
            defaults: .standard,
            currentKey: Self.remoteMCPKey
        )
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

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
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

    func isAutoApproved(_ actionName: String) -> Bool { autoApproveActions.contains(actionName) }

    func setAutoApprove(_ actionName: String, _ on: Bool) {
        guard isAutoApproved(actionName) != on else { return }
        if on {
            autoApproveActions.insert(actionName)
        } else {
            autoApproveActions.remove(actionName)
        }
        Log.service.info("ServiceManager.setAutoApprove action=\(actionName) on=\(on)")
    }

    func service(domain: String) -> Service? { byDomain[domain] }

    func connectRemoteMCP(
        _ rawEndpoint: String,
        transport: RemoteMCPTransport? = nil,
        allowsAuthorization: Bool = true
    ) async throws -> Service {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = trimmed.range(
            of: "^[A-Za-z][A-Za-z0-9+.-]*://",
            options: .regularExpression
        ) != nil
        let normalized = hasScheme ? trimmed : "https://\(trimmed)"
        guard let endpoint = URL(string: normalized), endpoint.absoluteString == normalized, endpoint.fragment == nil else {
            throw RemoteMCPError.invalidEndpoint
        }
        let service = services.first(where: { $0.definition.mcpEndpoint == endpoint })
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
        if byDomain[service.domain] == nil {
            resolvedServices = ResolvedServices(services + [service])
            monoRepositoryRevision &+= 1
            reindexMonoRepository()
        }
        if !persistedRemoteMCPServers.contains(where: { $0.endpoint == endpoint.absoluteString }) {
            persistedRemoteMCPServers.append(PersistedRemoteMCP(
                endpoint: endpoint.absoluteString,
                transport: service.definition.mcpTransport
            ))
            persistRemoteMCPServers()
        }
        setSaved(service, true)
        return service
    }

    func removeRemoteMCP(_ service: Service) {
        guard service.isMCPService, let endpoint = service.definition.mcpEndpoint else { return }
        let mcp = service.remoteMCPService
        persistedRemoteMCPServers.removeAll { $0.endpoint == endpoint.absoluteString }
        savedDomains.remove(service.domain)
        autoApproveActions = autoApproveActions.filter { !$0.hasPrefix("\(service.domain):") }
        if monoRepositoryMCPEndpoints.contains(endpoint.absoluteString) {
            Task {
                await mcp?.remove()
                service.resetMCPCapabilities()
            }
        } else {
            Task { await mcp?.remove() }
            resolvedServices = ResolvedServices(services.filter { $0.domain != service.domain })
        }
        monoRepositoryRevision &+= 1
        persistRemoteMCPServers()
        reindexMonoRepository()
        Log.service.info("RemoteMCP.remove id=\(service.domain) endpoint=\(LogPrivacy.url(service.url))")
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
        guard let service = byDomain[domain], !service.definition.isIOS else { return nil }
        let cacheKey = service.isMCPService ? "\(domain):\(preferredTheme ?? "any")" : domain
        if let data = faviconData[cacheKey] { return data }
        let data: Data?
        if service.isMCPService {
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
            guard let url = service.definition.faviconURL else {
                Log.service.info("Service.icon missing id=\(domain)")
                return nil
            }
            data = await ServiceImageLoader.data(url: url)
        }
        if let data {
            faviconData[cacheKey] = data
            if service.isMCPService {
                Log.service.info("RemoteMCP.icon loaded id=\(domain) bytes=\(data.count) theme=\(preferredTheme ?? "any")")
            } else {
                Log.service.info("Service.icon loaded id=\(domain) bytes=\(data.count)")
            }
        }
        return data
    }

    @discardableResult
    func refreshServices(locale: String?) async -> [String] {
        await loadRepositories(locale: locale)
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
                Log.service.info("ServiceManager.refreshServices unchanged monoRepository=\(monoRepository.hash.prefix(12))")
                return []
            }
            let stale = byDomain.values.filter { $0.webService != nil }
            for service in stale {
                service.invalidateResolved()
                faviconData[service.domain] = nil
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
        let previous = try? await repository.readSource(kind: kind.repositoryKind, id: domain, path: path)
        do {
            try await repository.writeLocalSource(kind: kind.repositoryKind, id: domain, path: path, data: data)
            try await validateLocalService(kind: kind, domain: domain)
        } catch {
            if let previous {
                try? await repository.writeLocalSource(kind: kind.repositoryKind, id: domain, path: path, data: previous)
            } else {
                try? await repository.deleteLocalSource(kind: kind.repositoryKind, id: domain, path: path)
            }
            throw error
        }
    }

    func deleteServiceSource(kind: ServicesMount.Kind, domain: String, path: [String]) async throws {
        let previous = try await repository.readSource(kind: kind.repositoryKind, id: domain, path: path)
        do {
            try await repository.deleteLocalSource(kind: kind.repositoryKind, id: domain, path: path)
            try await validateLocalService(kind: kind, domain: domain)
        } catch {
            try? await repository.writeLocalSource(kind: kind.repositoryKind, id: domain, path: path, data: previous)
            throw error
        }
    }

    func serviceSourcePaths(kind: ServicesMount.Kind, domain: String) async throws -> [String] {
        try await repository.sourcePaths(kind: kind.repositoryKind, id: domain)
    }

    private func validateLocalService(kind: ServicesMount.Kind, domain: String) async throws {
        switch kind {
        case .web:
            let manifestData = try await repository.readSource(
                kind: .web,
                id: domain,
                path: ["manifest.json"]
            )
            let raw = try JSONDecoder().decode(JSONValue.self, from: manifestData)
            let definition = try ServiceDefinition(manifest: raw, repositoryID: ServiceRepository.localID, provenance: .local)
            guard definition.domain == domain else {
                throw ServiceRepository.Failure(message: "manifest domain does not match its directory")
            }
            let actionsData = try await repository.readSource(kind: .web, id: domain, path: ["actions.js"])
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
            for skill in definition.skills {
                let data = try await repository.readSource(
                    kind: .web,
                    id: domain,
                    path: ["skills", skill.name, "SKILL.md"]
                )
                guard let content = String(data: data, encoding: .utf8),
                      SkillFiles.parse(content, directoryName: skill.name) != nil else {
                    throw ServiceRepository.Failure(message: "invalid skill \(skill.name)")
                }
            }
        case .mcp:
            let data = try await repository.readSource(kind: .mcp, id: domain, path: ["manifest.json"])
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
            try await validateLocalService(kind: kind, domain: service.runtimeID)
        }
    }

    func serviceForAttachment(domain: String) async throws -> Service {
        guard let service = service(domain: domain) else {
            throw ServiceRepository.Failure(message: "Service not found")
        }
        guard service.isWebService else {
            _ = await service.loadManifest(reason: .attach)
            return service
        }

        let definition: ServiceDefinition
        if service.isLocalService {
            try await validateLocalService(kind: .web, domain: domain)
            let manifestData = try await repository.readSource(kind: .web, id: domain, path: ["manifest.json"])
            let raw = try JSONDecoder().decode(JSONValue.self, from: manifestData)
            definition = try ServiceDefinition(
                manifest: Manifest.localized(raw, locale: monoRepositoryLocale),
                repositoryID: ServiceRepository.localID,
                provenance: .local
            )
        } else {
            definition = service.definition
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
            return ServiceDefinition(
                mcp: manifest.localized(locale),
                repositoryID: file.repositoryID
            )
        }
        Log.service.info("ServiceManager.listMCPServices count=\(definitions.count)")
        return definitions
    }

    // MARK: - Fetch

    struct Fetched { let actions: String; let skills: [String: String] }

    // Read the service's built artifacts from the working tree.
    func fetch(domain: String) async -> Fetched? {
        guard let definition = byDomain[domain]?.definition,
              let source = await repository.source(domain: domain, skills: definition.skills.map(\.name)) else {
            Log.service.error("ServiceManager.fetch missing in working tree domain=\(domain)")
            return nil
        }
        Log.service.info("ServiceManager.fetch ok domain=\(domain) actionsBytes=\(source.actions.utf8.count) skills=\(source.skills.count)")
        return Fetched(actions: source.actions, skills: source.skills)
    }

}

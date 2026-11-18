import Foundation
import Observation

@MainActor
@Observable
final class ConversationServiceAttachments {
    enum SystemEvent {
        case serviceLogin(String)
        case backgroundInterrupted

        var logLabel: String {
            switch self {
            case .serviceLogin(let domain): "serviceLogin:\(domain)"
            case .backgroundInterrupted: "backgroundInterrupted"
            }
        }
    }

    private(set) var services: [Service] = []
    @ObservationIgnored private(set) var domains: [String] = []
    @ObservationIgnored private var loadedDomains: Set<String> = []
    @ObservationIgnored private unowned let conversation: Conversation
    @ObservationIgnored private let cancelInteractions: (Set<String>) -> Void
    @ObservationIgnored private let resumeAgent: (JSONValue, SystemEvent) -> Void

    init(
        conversation: Conversation,
        cancelInteractions: @escaping (Set<String>) -> Void,
        resumeAgent: @escaping (JSONValue, SystemEvent) -> Void
    ) {
        self.conversation = conversation
        self.cancelInteractions = cancelInteractions
        self.resumeAgent = resumeAgent
    }

    private var id: UUID { conversation.id }
    private var serviceManager: ServiceManager { conversation.serviceManager }
    var loadedServices: [Service] { loadedDomains.sorted().compactMap { serviceManager.service(domain: $0) } }

    func restore(_ stored: [String]) {
        domains = Self.uniqueDomains(stored)
        if domains.count != stored.count {
            Log.session.warning("Conversation.restore deduplicated-services id=\(id) stored=\(stored.count) unique=\(domains.count)")
        }
        resolve()
    }

    func service(domain: String) -> Service? {
        services.first { $0.domain == domain }
    }

    func resolveService(_ domain: String) async throws -> Service {
        let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
        if serviceManager.service(domain: domain) == nil {
            await serviceManager.refreshServices(locale: locale)
        }
        var candidate = try await serviceManager.serviceForAttachment(domain: domain)
        if let current = serviceManager.service(domain: candidate.domain), current.sourceVersion != candidate.sourceVersion {
            await serviceManager.refreshServices(locale: locale)
            candidate = try await serviceManager.serviceForAttachment(domain: candidate.domain)
        }
        let service = try await serviceManager.selectServiceForAttachment(candidate)
        if let index = services.firstIndex(where: { $0.domain == service.domain }) {
            var updated = services
            updated[index] = service
            replace(updated)
        }
        loadedDomains.insert(service.domain)
        if conversation.isSelected {
            serviceManager.setAttachedServices(loadedServices, for: id)
        }
        Log.session.info("Conversation.service resolved id=\(id) domain=\(service.domain) source=\(service.sourceVersion ?? "none")")
        return service
    }

    func target(_ name: String, label: String) async throws -> (service: Service, id: String) {
        let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, ["web", "api", "ios", "mcp"].contains(parts[0]) {
            guard !parts[1].isEmpty, !parts[2].isEmpty else {
                throw RuntimeError.bridge("\(label): service and action must be non-empty")
            }
            let domain = parts[0] == "ios" ? "ios:\(parts[1])" : parts[1]
            let service = try await resolveService(domain)
            guard ServiceOperations.serviceKind(service) == parts[0] else {
                throw Service.InvokeError.unknown(name)
            }
            return (service, parts[2])
        }
        throw RuntimeError.bridge("\(label): use a qualified web:<domain>:<action>, api:<service>:<action>, ios:<app>:<action>, or mcp:<server>:<action> name.")
    }

    func set(_ supplied: [Service]) {
        let canonical = supplied.map { serviceManager.service(domain: $0.domain) ?? $0 }
        let normalized = Self.uniqueServices(canonical)
        if normalized.count != supplied.count {
            Log.session.warning("Conversation.setAttachedServices deduplicated id=\(id) supplied=\(supplied.count) unique=\(normalized.count)")
        }
        let normalizedDomains = normalized.map(\.domain)
        guard normalizedDomains != domains else {
            replace(normalized)
            return
        }
        domains = normalizedDomains
        replace(normalized)
        conversation.onPersistableChange?()
    }

    func attach(_ service: Service) -> Bool {
        guard !domains.contains(service.domain) else { return false }
        domains.append(service.domain)
        if !services.contains(where: { $0.domain == service.domain }) {
            replace(services + [service])
        }
        conversation.onPersistableChange?()
        return true
    }

    func detach(domain: String) {
        domains.removeAll { $0 == domain }
        replace(services.filter { $0.domain != domain })
        conversation.onPersistableChange?()
        Log.session.info("Conversation.detachService id=\(id) domain=\(domain)")
    }

    func attach(domains requested: [String]) -> Bool {
        let monoRepositoryReady = serviceManager.monoRepositoryState == .ready
        var known = Set(domains)
        var added: [String] = []
        var unavailable: [String] = []
        for domain in requested where known.insert(domain).inserted {
            if serviceManager.service(domain: domain) != nil || !monoRepositoryReady {
                added.append(domain)
            } else {
                unavailable.append(domain)
            }
        }
        if !unavailable.isEmpty {
            Log.session.warning("Conversation.attachServiceDomains id=\(id) unavailable=\(unavailable.joined(separator: ","))")
        }
        guard !added.isEmpty else {
            resolve()
            return false
        }
        domains.append(contentsOf: added)
        resolve()
        let resolved = added.filter { serviceManager.service(domain: $0) != nil }
        let deferred = added.filter { serviceManager.service(domain: $0) == nil }
        Log.session.info("Conversation.attachServiceDomains id=\(id) resolved=\(resolved.joined(separator: ",")) deferred=\(deferred.joined(separator: ","))")
        conversation.onPersistableChange?()
        return true
    }

    func resolve() {
        let migratedDomains = ConversationMigrator.migratedServiceDomains(domains, services: serviceManager)
        if migratedDomains != domains {
            Log.session.info("Conversation.resolveAttachedServices migrated id=\(id) from=\(domains.joined(separator: ",")) to=\(migratedDomains.joined(separator: ","))")
            domains = migratedDomains
            conversation.onPersistableChange?()
        }
        let normalizedDomains = Self.uniqueDomains(domains)
        if normalizedDomains.count != domains.count {
            Log.session.warning("Conversation.resolveAttachedServices deduplicated id=\(id) stored=\(domains.count) unique=\(normalizedDomains.count)")
            domains = normalizedDomains
        }
        replace(domains.compactMap { serviceManager.service(domain: $0) })
    }

    private static func uniqueDomains(_ domains: [String]) -> [String] {
        var seen: Set<String> = []
        return domains.filter { seen.insert($0).inserted }
    }

    private static func uniqueServices(_ services: [Service]) -> [Service] {
        var normalized: [Service] = []
        var indexByDomain: [String: Int] = [:]
        for service in services {
            if let index = indexByDomain[service.domain] {
                normalized[index] = service
            } else {
                indexByDomain[service.domain] = normalized.count
                normalized.append(service)
            }
        }
        return normalized
    }

    private func replace(_ replacement: [Service]) {
        assert(Set(replacement.map(\.domain)).count == replacement.count)
        assert(replacement.allSatisfy { serviceManager.service(domain: $0.domain) === $0 })
        loadedDomains.formUnion(replacement.map(\.domain))
        let unchanged = replacement.count == services.count
            && zip(replacement, services).allSatisfy { pair in pair.0 === pair.1 }
        guard !unchanged else { return }
        let removed = services.filter { candidate in
            !replacement.contains { $0 === candidate }
        }
        let added = replacement.filter { candidate in
            !services.contains { $0 === candidate }
        }
        cancelInteractions(Set(removed.filter { serviceManager.service(domain: $0.domain) !== $0 }.map(\.domain)))
        services = replacement
        Log.session.info("Conversation.setAttachedServices id=\(id) attached=\(replacement.map(\.domain).joined(separator: ",")) selected=\(conversation.isSelected)")
        if conversation.isSelected {
            serviceManager.setAttachedServices(loadedServices, for: id)
        }
        for svc in added {
            Log.session.info("Conversation.serviceManifest prepare id=\(id) domain=\(svc.domain)")
            Task { _ = await svc.loadManifest(reason: .attach) }
        }
    }

    func login(
        domain: String,
        resumeAgent resumes: Bool
    ) async -> JSONValue? {
        guard let service = service(domain: domain) else {
            Log.session.error("Conversation.loginService no service domain=\(domain)")
            return nil
        }
        Log.session.info("Conversation.loginService start id=\(id) domain=\(domain) auth=\(service.loginState.rawValue) resumeAgent=\(resumes)")
        _ = try? await service.requestAccess(source: .conversationCard)
        let ok = service.loginState.isAuthenticated
        let result = ok ? service.accessResult() : nil
        Log.session.info("Conversation.loginService done id=\(id) domain=\(domain) ok=\(ok) auth=\(service.loginState.rawValue)")
        if ok, resumes {
            resumeAgent(
                .object(["type": .string("serviceLogin"), "domain": .string(domain), "authorized": .bool(!service.isWebService)]),
                .serviceLogin(domain)
            )
        }
        return result
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class ConversationServiceAttachments {
    enum SystemEvent {
        case serviceLogin(String)

        var logLabel: String {
            switch self {
            case .serviceLogin(let domain): "serviceLogin:\(domain)"
            }
        }
    }

    private(set) var services: [Service] = []
    @ObservationIgnored private(set) var domains: [String] = []
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

    func target(_ name: String, label: String) throws -> (service: Service, id: String) {
        let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, ["web", "api", "ios", "mcp"].contains(parts[0]) {
            let service = services.first { candidate in
                switch parts[0] {
                case "web": candidate.isWebService && candidate.domain == parts[1]
                case "api": candidate.isAPIService && candidate.domain == parts[1]
                case "ios": candidate.isIOSService && candidate.domain == "ios:\(parts[1])"
                case "mcp": candidate.isMCPService && candidate.domain == parts[1]
                default: false
                }
            }
            guard let service else {
                throw OxFunctionError(code: "service_not_attached", message: "\(label): service '\(parts[0]):\(parts[1])' isn't attached to this conversation.", recovery: "Find the service with ox.service.find and attach its exact returned domain with ox.service.attach before invoking its actions.")
            }
            return (service, parts[2])
        }
        if services.count == 1, let only = services.first {
            return (only, name)
        }
        throw RuntimeError.bridge("\(label): use 'web:<domain>:\(name)', 'ios:<app>:\(name)', or 'mcp:<server>:\(name)' — the conversation has \(services.count) services attached.")
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
        guard !services.contains(where: { $0.domain == service.domain }) else { return false }
        set(services + [service])
        return true
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
        let unchanged = replacement.count == services.count
            && zip(replacement, services).allSatisfy { pair in pair.0 === pair.1 }
        guard !unchanged else { return }
        let removed = services.filter { candidate in
            !replacement.contains { $0 === candidate }
        }
        cancelInteractions(Set(removed.map(\.domain)))
        services = replacement
        Log.session.info("Conversation.setAttachedServices id=\(id) attached=\(replacement.map(\.domain).joined(separator: ",")) selected=\(conversation.isSelected)")
        if conversation.isSelected {
            serviceManager.setAttachedServices(replacement, for: id)
        }
        for svc in replacement {
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
                .object(["type": .string("serviceSignIn"), "domain": .string(domain), "access": result ?? .null]),
                .serviceLogin(domain)
            )
        }
        return result
    }
}

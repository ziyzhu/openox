import Foundation

extension ServiceManager {
    func prepareServices(domains: [String], locale: String?) async throws -> [Service] {
        try Task.checkCancellation()
        await refreshServices(locale: locale)
        try Task.checkCancellation()
        if case .failed(let message) = repositoryState {
            throw RuntimeError.bridge("Service catalog could not be loaded: \(message)")
        }
        let resolved = try requireServices(domains: domains)
        let required = resolved.map(\.domain)
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

    @discardableResult
    func requireServices(domains: [String]) throws -> [Service] {
        guard monoRepositoryState == .ready else {
            throw RuntimeError.bridge("Service catalog is not ready.")
        }
        var seen = Set<String>()
        let required = domains.filter { seen.insert($0).inserted }
        let missing = required.filter { service(domain: $0) == nil }
        guard missing.isEmpty else {
            throw RuntimeError.bridge("Required service is not installed or enabled: \(missing.joined(separator: ", ")). Install or enable its repository in Settings > Repositories.")
        }
        return required.compactMap { service(domain: $0) }
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

    func defaultPolicy(for action: String) -> ActionPolicy {
        if action.hasPrefix("\(Actions.serviceAttach):") { return Actions.defaultPolicy(for: Actions.serviceAttach) }
        if Actions.builtIn.contains(action) { return Actions.defaultPolicy(for: action) }
        for service in services {
            guard let serviceAction = service.definition.exposedActions.first(where: {
                service.definition.qualifiedActionName($0.id) == action
            }) else { continue }
            return serviceAction.requireApproval ? .ask : .allow
        }
        return .ask
    }

    func inspectionService(domain: String) -> Service? {
        if domain == BrowserFunctionCatalog.publicNamespace || domain == BrowserFunctionCatalog.internalDomain {
            return browserService
        }
        return service(domain: domain)
    }
}

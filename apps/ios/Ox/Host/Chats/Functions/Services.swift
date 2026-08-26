import Foundation

extension Chat: OxFunctionBridge {
    public func createService(kind: String, domain: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.createService(kind: kind, domain: domain, purpose: purpose)
    }

    public func copyService(domain: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.copyService(domain: domain, purpose: purpose)
    }

    public func deleteService(domain: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.deleteService(domain: domain, purpose: purpose)
    }

    public func serviceGitStatus(repository: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.serviceGitStatus(repository: repository, purpose: purpose)
    }

    public func serviceGitLog(
        repository: String,
        limit: Int,
        cursor: String?,
        purpose: String
    ) async throws -> JSONValue? {
        try await serviceOperations.serviceGitLog(repository: repository, limit: limit, cursor: cursor, purpose: purpose)
    }

    public func serviceGitShow(
        repository: String,
        commitHash: String,
        path: String?,
        purpose: String
    ) async throws -> JSONValue? {
        try await serviceOperations.serviceGitShow(repository: repository, commitHash: commitHash, path: path, purpose: purpose)
    }

    public func serviceGitDiff(
        repository: String,
        commitHash: String?,
        baseCommitHash: String?,
        path: String?,
        purpose: String
    ) async throws -> JSONValue? {
        try await serviceOperations.serviceGitDiff(repository: repository, commitHash: commitHash, baseCommitHash: baseCommitHash, path: path, purpose: purpose)
    }

    public func serviceGitCheckout(repository: String, commitHash: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.serviceGitCheckout(repository: repository, commitHash: commitHash, purpose: purpose)
    }

    public func serviceGitCommit(message: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.serviceGitCommit(message: message, purpose: purpose)
    }

    public func serviceGitRevert(commitHash: String, message: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.serviceGitRevert(commitHash: commitHash, message: message, purpose: purpose)
    }

    public func serviceGitRestore(path: String?, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.serviceGitRestore(path: path, purpose: purpose)
    }

    public func listAttachedServices(kind: String?, purpose: String) async throws -> JSONValue? {
        guard kind == nil || kind == "web" || kind == "ios" || kind == "mcp" else {
            throw RuntimeError.bridge("ox.service.listAttached: kind must be 'web', 'ios', or 'mcp'")
        }
        let args: JSONValue = .object(kind.map { ["kind": .string($0)] } ?? [:])
        return try await tracked(.serviceListAttached, args, purpose: purpose) {
            let snapshots = try self.attachedServices
                .filter { kind == nil || self.serviceKind($0) == kind }
                .sorted { $0.domain < $1.domain }
                .map { try self.serviceSnapshot($0) }
            Log.session.info("bridge.service.listAttached kind=\(kind ?? "all") count=\(snapshots.count)")
            return .array(snapshots)
        }
    }

    public func inspectService(domain: String, actions: [String]?, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.inspectService(domain: domain, actions: actions, purpose: purpose)
    }

    private func serviceSnapshot(_ service: Service) throws -> JSONValue {
        guard case .object(var fields) = try Self.encodeToJSON(service.snapshot(attached: true)) else {
            throw RuntimeError.bridge("service snapshot is not an object")
        }
        fields["kind"] = .string(serviceKind(service))
        if case .repository(let id, let provenance) = service.definition.source {
            fields["repository"] = .string(id)
            fields["repositoryProvenance"] = .string(provenance.rawValue)
        }
        return .object(fields)
    }

    private func serviceKind(_ service: Service) -> String {
        if service.isIOSService { return "ios" }
        if service.isMCPService { return "mcp" }
        return "web"
    }

    public func invokeAction(name: String, args: JSONValue?, purpose: String) async throws -> JSONValue? {
        switch await callService(name: name, args: args ?? .object([:]), purpose: purpose) {
        case .success(let value): return value
        case .failure(let e): throw e
        }
    }
}

extension Chat {
    func requireIOSService(_ id: String) throws {
        guard attachedServices.contains(where: { $0.domain == id }) else {
            throw RuntimeError.bridge("\(id) isn't attached to this chat. Find and attach it before using this iOS service.")
        }
    }

    public func findServices(query: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.findServices(query: query, purpose: purpose)
    }

    public func attachService(domain: String, purpose: String) async throws -> JSONValue? {
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("ox.service.attach: requires a non-empty domain")
        }
        guard serviceManager.service(domain: domain) != nil else {
            throw RuntimeError.bridge("ox.service.attach: no service with domain '\(domain)'. Inspect services/<kind>/<id>/service.json to get a valid domain.")
        }
        let existing = attachedService(domain: domain)
        let service = try await serviceManager.serviceForCaller(domain: domain, reason: .attach)
        if existing == nil { try await gateServiceAttach(service) }
        return try await tracked(.serviceAttach, .object(["domain": .string(domain)]), purpose: purpose) {
            serviceManager.selectServiceForAttachment(service)
            serviceManager.setSaved(service, true)
            if let existing, let index = attachedServices.firstIndex(where: { $0 === existing }) {
                var services = attachedServices
                services[index] = service
                setAttachedServices(services)
            } else {
                setAttachedServices(attachedServices + [service])
            }
            guard case .object(var result) = try Self.encodeToJSON(service.snapshot(attached: true)) else {
                throw RuntimeError.bridge("ox.service.attach: failed to encode service snapshot")
            }
            result["reloaded"] = .bool(existing != nil)
            let snapshot = service.snapshot(attached: true)
            Log.session.info("bridge.service.attach domain=\(domain) reloaded=\(existing != nil) signIn=\(snapshot.signIn.rawValue)")
            return .object(result)
        }
    }

    public func signInService(domain: String, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.signInService(domain: domain, purpose: purpose)
    }

    public func solveService(domain: String, args: JSONValue, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.solveService(domain: domain, args: args, purpose: purpose)
    }

    public func payService(domain: String, args: JSONValue, purpose: String) async throws -> JSONValue? {
        try await serviceOperations.payService(domain: domain, args: args, purpose: purpose)
    }

    public func detachService(domain: String, purpose: String) async throws -> JSONValue? {
        try await tracked(.serviceDetach, .object(["domain": .string(domain)]), purpose: purpose) {
            guard !domain.isEmpty else {
                throw RuntimeError.bridge("ox.service.detach: requires a non-empty domain")
            }
            guard let service = attachedService(domain: domain) ?? serviceManager.service(domain: domain) else {
                throw RuntimeError.bridge("ox.service.detach: no service with domain '\(domain)'.")
            }
            guard attachedService(domain: domain) != nil else {
                Log.session.info("bridge.service.detach not attached domain=\(domain)")
                return try Self.encodeToJSON(service.snapshot(attached: false))
            }
            setAttachedServices(attachedServices.filter { $0.domain != domain })
            Log.session.info("bridge.service.detach detached domain=\(domain)")
            return try Self.encodeToJSON(service.snapshot(attached: false))
        }
    }

}

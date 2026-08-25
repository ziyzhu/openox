import Foundation

extension Chat: OxFunctionBridge {
    public func createService(kind: String, domain: String, purpose: String) async throws -> JSONValue? {
        guard let serviceKind = ServiceRepository.ServiceKind(rawValue: kind), serviceKind == .web else {
            throw RuntimeError.bridge("ox.service.create: kind must be 'web'")
        }
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let args: JSONValue = .object(["kind": .string(kind), "domain": .string(cleanDomain)])
        return try await tracked(.serviceCreate, args, purpose: purpose) {
            try await self.requireApproval(action: InvocationName.serviceCreate.rawValue, args: args.toAny())
            try await self.serviceManager.createService(
                kind: serviceKind,
                id: cleanDomain,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object([
                "domain": .string(cleanDomain),
                "manifestPath": .string("services/web/\(cleanDomain)/manifest.json"),
                "source": .string("local"),
            ])
        }
    }

    public func copyService(domain: String, purpose: String) async throws -> JSONValue? {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let service = serviceManager.service(domain: cleanDomain) else {
            throw RuntimeError.bridge("ox.service.copy: service '\(cleanDomain)' does not exist.")
        }
        let kind = serviceKind(service)
        let args: JSONValue = .object(["domain": .string(cleanDomain)])
        return try await tracked(.serviceCopy, args, purpose: purpose) {
            try await self.requireApproval(action: InvocationName.serviceCopy.rawValue, args: args.toAny())
            try await self.serviceManager.copyServiceToLocal(
                domain: cleanDomain,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object([
                "domain": .string(cleanDomain),
                "manifestPath": .string("services/\(kind)/\(cleanDomain)/manifest.json"),
                "source": .string("local"),
            ])
        }
    }

    public func deleteService(domain: String, purpose: String) async throws -> JSONValue? {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let currentService = serviceManager.service(domain: cleanDomain)
        let args: JSONValue = .object(["domain": .string(cleanDomain)])
        return try await tracked(.serviceDelete, args, purpose: purpose) {
            try await self.requireApproval(action: InvocationName.serviceDelete.rawValue, args: args.toAny())
            let kind = try await self.serviceManager.deleteLocalService(
                domain: cleanDomain,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            let replacement = self.serviceManager.service(domain: cleanDomain)
            if replacement == nil {
                if let currentService { self.serviceManager.setSaved(currentService, false) }
                self.setAttachedServices(self.attachedServices.filter { $0.domain != cleanDomain })
            } else if let replacement, self.attachedServices.contains(where: { $0.domain == cleanDomain }) {
                self.setAttachedServices(self.attachedServices.map { $0.domain == cleanDomain ? replacement : $0 })
            }
            var result: [String: JSONValue] = [
                "domain": .string(cleanDomain),
                "kind": .string(kind.rawValue),
                "deleted": .bool(true),
                "source": .string("local"),
            ]
            if let replacement,
               case .repository(let repository, let provenance) = replacement.definition.source {
                result["replacementRepository"] = .string(repository)
                result["replacementProvenance"] = .string(provenance.rawValue)
            }
            return .object(result)
        }
    }

    public func serviceGitStatus(repository: String, purpose: String) async throws -> JSONValue? {
        let repository = try serviceRepositoryID(repository, function: "status")
        return try await tracked(.serviceGitStatus, .object(["repository": .string(repository)]), purpose: purpose) {
            try Self.encodeToJSON(try await self.serviceManager.serviceGitStatus(repositoryID: repository))
        }
    }

    public func serviceGitLog(
        repository: String,
        limit: Int,
        cursor: String?,
        purpose: String
    ) async throws -> JSONValue? {
        let repository = try serviceRepositoryID(repository, function: "log")
        guard (1...100).contains(limit) else {
            throw RuntimeError.bridge("ox.service.git.log: limit must be between 1 and 100")
        }
        var fields: [String: JSONValue] = [
            "repository": .string(repository),
            "limit": .int(limit),
        ]
        if let cursor { fields["cursor"] = .string(cursor) }
        return try await tracked(.serviceGitLog, .object(fields), purpose: purpose) {
            try Self.encodeToJSON(try await self.serviceManager.serviceGitLog(
                repositoryID: repository,
                limit: limit,
                cursor: cursor
            ))
        }
    }

    public func serviceGitShow(
        repository: String,
        commitHash: String,
        path: String?,
        purpose: String
    ) async throws -> JSONValue? {
        let repository = try serviceRepositoryID(repository, function: "show")
        var fields: [String: JSONValue] = [
            "repository": .string(repository),
            "commitHash": .string(commitHash),
        ]
        if let path { fields["path"] = .string(path) }
        return try await tracked(.serviceGitShow, .object(fields), purpose: purpose) {
            try Self.encodeToJSON(try await self.serviceManager.serviceGitShow(
                repositoryID: repository,
                commitHash: commitHash,
                path: path
            ))
        }
    }

    public func serviceGitDiff(
        repository: String,
        commitHash: String?,
        baseCommitHash: String?,
        path: String?,
        purpose: String
    ) async throws -> JSONValue? {
        let repository = try serviceRepositoryID(repository, function: "diff")
        guard commitHash != nil || baseCommitHash == nil else {
            throw RuntimeError.bridge("ox.service.git.diff: commitHash is required when baseCommitHash is provided")
        }
        var fields: [String: JSONValue] = ["repository": .string(repository)]
        if let commitHash { fields["commitHash"] = .string(commitHash) }
        if let baseCommitHash { fields["baseCommitHash"] = .string(baseCommitHash) }
        if let path { fields["path"] = .string(path) }
        return try await tracked(.serviceGitDiff, .object(fields), purpose: purpose) {
            try Self.encodeToJSON(try await self.serviceManager.serviceGitDiff(
                repositoryID: repository,
                commitHash: commitHash,
                baseCommitHash: baseCommitHash,
                path: path
            ))
        }
    }

    public func serviceGitCheckout(repository: String, commitHash: String, purpose: String) async throws -> JSONValue? {
        let repository = try serviceRepositoryID(repository, function: "checkout")
        let args: JSONValue = .object([
            "repository": .string(repository),
            "commitHash": .string(commitHash),
        ])
        return try await tracked(.serviceGitCheckout, args, purpose: purpose) {
            try await self.requireApproval(action: InvocationName.serviceGitCheckout.rawValue, args: args.toAny())
            return try Self.encodeToJSON(try await self.serviceManager.checkoutServiceRepository(
                repositoryID: repository,
                commitHash: commitHash,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            ))
        }
    }

    public func serviceGitCommit(message: String, purpose: String) async throws -> JSONValue? {
        let message = try serviceCommitMessage(message, function: "commit")
        let args: JSONValue = .object(["message": .string(message)])
        return try await tracked(.serviceGitCommit, args, purpose: purpose) {
            try await self.requireApproval(action: InvocationName.serviceGitCommit.rawValue, args: args.toAny())
            return try Self.encodeToJSON(try await self.serviceManager.commitLocalServices(
                message: message,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            ))
        }
    }

    public func serviceGitRevert(commitHash: String, message: String, purpose: String) async throws -> JSONValue? {
        let message = try serviceCommitMessage(message, function: "revert")
        let args: JSONValue = .object([
            "commitHash": .string(commitHash),
            "message": .string(message),
        ])
        return try await tracked(.serviceGitRevert, args, purpose: purpose) {
            try await self.requireApproval(action: InvocationName.serviceGitRevert.rawValue, args: args.toAny())
            return try Self.encodeToJSON(try await self.serviceManager.revertLocalServices(
                commitHash: commitHash,
                message: message,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            ))
        }
    }

    public func serviceGitRestore(path: String?, purpose: String) async throws -> JSONValue? {
        let path = try path.map(serviceRestorePath)
        let status = try await serviceManager.serviceGitStatus(repositoryID: ServiceRepository.localID)
        var fields: [String: JSONValue] = [
            "staged": .array(status.staged.map(JSONValue.string)),
            "unstaged": .array(status.unstaged.map(JSONValue.string)),
            "untracked": .array(status.untracked.map(JSONValue.string)),
        ]
        if let path { fields["path"] = .string(path) }
        let args: JSONValue = .object(fields)
        return try await tracked(.serviceGitRestore, args, purpose: purpose) {
            try await self.requireApproval(action: InvocationName.serviceGitRestore.rawValue, args: args.toAny())
            return try Self.encodeToJSON(try await self.serviceManager.restoreLocalServices(
                path: path,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            ))
        }
    }

    private func serviceRepositoryID(_ value: String, function: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean == ServiceRepository.localID else {
            throw RuntimeError.bridge("ox.service.git.\(function): repository must be 'local'")
        }
        return clean
    }

    private func serviceRestorePath(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = clean.hasPrefix("services/") ? String(clean.dropFirst("services/".count)) : clean
        guard !path.isEmpty else {
            throw RuntimeError.bridge("ox.service.git.restore: path cannot be empty")
        }
        return path
    }

    private func serviceCommitMessage(_ value: String, function: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 500 else {
            throw RuntimeError.bridge("ox.service.git.\(function): message must contain 1-500 characters")
        }
        return clean
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
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDomain.isEmpty, cleanDomain.count <= 500 else {
            throw RuntimeError.bridge("ox.service.inspect: domain must contain 1-500 characters")
        }
        if let actions {
            guard (1...10).contains(actions.count),
                  actions.allSatisfy({ !$0.isEmpty && $0.count <= 500 }),
                  Set(actions).count == actions.count else {
                throw RuntimeError.bridge("ox.service.inspect: actions must contain 1-10 unique action IDs of 1-500 characters")
            }
        }
        guard let service = attachedServices.first(where: { $0.domain == cleanDomain }) else {
            throw RuntimeError.bridge("ox.service.inspect: service '\(cleanDomain)' isn't attached to this chat.")
        }
        guard await service.loadManifest(reason: .inspect) != nil else {
            throw RuntimeError.bridge("ox.service.inspect: service '\(cleanDomain)' capabilities are unavailable; authorize or retry the service first.")
        }
        var fields: [String: JSONValue] = ["domain": .string(cleanDomain)]
        if let actions { fields["actions"] = .array(actions.map(JSONValue.string)) }
        return try await tracked(.serviceInspect, .object(fields), purpose: purpose) {
            let definition = service.definition
            let details: [String: JSONValue]
            if let actions {
                details = try Dictionary(uniqueKeysWithValues: actions.map { id in
                    guard let detail = OxActions.detail(definition: definition, id: id) else {
                        throw RuntimeError.bridge("ox.service.inspect: unknown exposed action '\(cleanDomain):\(id)'.")
                    }
                    return (id, detail)
                })
            } else {
                let index = OxActions.index(definition: definition)
                details = Dictionary(uniqueKeysWithValues: definition.exposedActions.map { action in
                    (action.id, index[definition.qualifiedActionName(action.id)] ?? .object([:]))
                })
            }
            Log.session.info("bridge.service.inspect domain=\(cleanDomain) schemas=\(actions != nil) count=\(details.count)")
            var result: [String: JSONValue] = [
                "service": try self.serviceSnapshot(service),
                "actions": .object(details),
            ]
            if let payment = OxActions.paymentDetail(definition: definition) {
                result["payment"] = payment
            }
            return .object(result)
        }
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
    public func findServices(query: String, purpose: String) async throws -> JSONValue? {
        try await tracked(.serviceFind, .object(["query": .string(query)]), purpose: purpose) {
            guard serviceManager.monoRepositoryState == .ready else {
                Log.session.info("bridge.service.find unavailable monoRepository=loading chars=\(query.count)")
                throw RuntimeError.bridge("ox.service.find: Ox Server is still loading services. Continue without service discovery or try again later.")
            }
            let matches = await serviceManager.search(query, filter: .all).prefix(5)
            let attached = Set(attachedServices.map(\.domain))
            let results = matches.map {
                ServiceFindResult(
                    match: $0,
                    attached: attached.contains($0.service.domain),
                    kind: serviceKind($0.service)
                )
            }
            Log.session.info("bridge.service.find chars=\(query.count) hits=\(results.count)")
            return try Self.encodeToJSON(results)
        }
    }

    private struct ServiceFindResult: Encodable {
        struct MatchedAction: Encodable {
            let id: String
            let label: String
        }

        let domain: String
        let kind: String
        let manifestPath: String
        let repository: String?
        let repositoryProvenance: String?
        let name: String
        let description: String?
        let signIn: Service.SignInState
        let saved: Bool
        let attached: Bool
        let skills: [Manifest.Skill]
        let matchedAction: MatchedAction?

        init(match: ServiceManager.ServiceMatch, attached: Bool, kind: String) {
            let snapshot = match.service.snapshot(attached: attached)
            domain = snapshot.domain
            self.kind = kind
            manifestPath = "services/\(kind)/\(snapshot.domain)/manifest.json"
            if case .repository(let id, let provenance) = match.service.definition.source {
                repository = id
                repositoryProvenance = provenance.rawValue
            } else {
                repository = nil
                repositoryProvenance = nil
            }
            name = snapshot.name
            description = snapshot.description
            signIn = snapshot.signIn
            saved = snapshot.saved
            self.attached = snapshot.attached
            skills = snapshot.skills
            matchedAction = match.matchedActionID.flatMap { id in
                match.matchedAction.map { MatchedAction(id: id, label: $0) }
            }
        }
    }

    public func attachService(domain: String, purpose: String) async throws -> JSONValue? {
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("ox.service.attach: requires a non-empty domain")
        }
        guard serviceManager.service(domain: domain) != nil else {
            throw RuntimeError.bridge("ox.service.attach: no service with domain '\(domain)'. Inspect services/<kind>/<id>/manifest.json to get a valid domain.")
        }
        let existing = attachedService(domain: domain)
        let service = try await serviceManager.serviceForAttachment(domain: domain)
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
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("ox.service.signIn: requires a non-empty domain")
        }
        guard let service = attachedService(domain: domain) else {
            throw RuntimeError.bridge("ox.service.signIn: \(domain) is not attached to this chat")
        }
        guard service.supportsAuthentication else {
            throw RuntimeError.bridge("ox.service.signIn: \(domain) declares no sign-in handoff")
        }
        return try await tracked(.serviceSignIn, .object(["domain": .string(domain)]), purpose: purpose) {
            await service.resolveSignInState(reason: .modelSignIn)
            if service.auth.isSignedOut {
                await service.attemptSilentSignIn(reason: .modelSignIn)
            }
            if service.signInState.isAuthenticated {
                Log.session.info("bridge.service.signIn already authenticated domain=\(domain) auth=\(service.signInState.rawValue)")
                return .object([
                    "domain": .string(domain),
                    "signedIn": .bool(true),
                ])
            }
            let control = ServiceControl.signIn(domain: domain, serviceName: service.title)
            Log.session.info("bridge.service.signIn handoff domain=\(domain) auth=\(service.signInState.rawValue)")
            let pending = self.embedServiceControl(control)
            guard await self.waitForServiceControl(pending) != nil else {
                throw RuntimeError.bridge("ox.service.signIn: the user cancelled or sign-in failed")
            }
            return .object([
                "domain": .string(domain),
                "signedIn": .bool(true),
            ])
        }
    }

    public func solveService(domain: String, args: JSONValue, purpose: String) async throws -> JSONValue? {
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("ox.service.solve: requires a non-empty domain")
        }
        guard args.objectValue != nil else {
            throw RuntimeError.bridge("ox.service.solve: args must be an object")
        }
        guard let service = attachedService(domain: domain) else {
            throw RuntimeError.bridge("ox.service.solve: \(domain) is not attached to this chat")
        }
        guard service.supportsBotControl else {
            throw RuntimeError.bridge("ox.service.solve: \(domain) does not support human verification")
        }
        return try await tracked(.serviceSolve, .object(["domain": .string(domain), "args": args]), purpose: purpose) {
            let control = ServiceControl.botControl(domain: domain, serviceName: service.title, args: args)
            Log.session.info("bridge.service.solve handoff domain=\(domain)")
            let pending = self.embedServiceControl(control)
            guard await self.waitForServiceControl(pending) != nil else {
                throw RuntimeError.bridge("ox.service.solve: the user cancelled or verification failed")
            }
            return .null
        }
    }

    public func payService(domain: String, args: JSONValue, purpose: String) async throws -> JSONValue? {
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("ox.service.pay: requires a non-empty domain")
        }
        guard args.objectValue != nil else {
            throw RuntimeError.bridge("ox.service.pay: args must be an object")
        }
        guard let service = attachedService(domain: domain) else {
            throw RuntimeError.bridge("ox.service.pay: \(domain) is not attached to this chat")
        }
        guard service.definition.action(Manifest.PAYMENT_URL_ACTION_ID, includingStandard: true) != nil,
              service.definition.action(Manifest.PAYMENT_STATE_ACTION_ID, includingStandard: true) != nil else {
            throw RuntimeError.bridge("ox.service.pay: \(domain) declares no payment handoff")
        }
        return try await tracked(.servicePayment, .object(["domain": .string(domain), "args": args]), purpose: purpose) {
            let control = ServiceControl.payment(domain: domain, serviceName: service.title, args: args)
            Log.session.info("bridge.service.payment handoff domain=\(domain)")
            let pending = self.embedServiceControl(control)
            guard let result = await self.waitForServiceControl(pending) else {
                throw RuntimeError.bridge("ox.service.pay: the user cancelled or checkout did not complete")
            }
            return result
        }
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

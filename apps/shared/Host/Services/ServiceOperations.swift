import Foundation

@MainActor
final class ServiceOperations {
    private static let maximumFindResults = 10

    let serviceManager: ServiceManager
    let conversationOwner: WebConversation.Owner
    let resolveConversationAttachments: ([JSONValue]) async throws -> [WebsiteAttachment]
    let resolveService: (String) async throws -> Service
    let resolveAction: (String) async throws -> (Service, String)
    let attachedDomains: () -> Set<String>
    let requireApproval: (String, ActionPolicy, Any?, String?, String?) async throws -> Void
    let presentControl: (ServiceControl, Service) async -> JSONValue?
    let receiveFiles: @MainActor ([RemoteMCPFile]) async throws -> Void
    let serviceChanged: (String) -> Void
    let botControlRequired: (Service, JSONValue, Service.ServiceWebPage) -> Void
    let begin: (String, JSONValue, String) -> UUID
    let finish: (UUID, Result<JSONValue?, Error>) -> Void
    let native: NativeServiceOperations
    let authenticationRecovery: ServiceAuthenticationRecoveryStore

    init(
        serviceManager: ServiceManager,
        conversationOwner: WebConversation.Owner,
        resolveConversationAttachments: @escaping ([JSONValue]) async throws -> [WebsiteAttachment] = { refs in
            guard refs.isEmpty else { throw WebsiteProviderError("This caller cannot stage website attachments", kind: .unsupportedInput) }
            return []
        },
        resolveService: @escaping (String) async throws -> Service,
        resolveAction: @escaping (String) async throws -> (Service, String),
        attachedDomains: @escaping () -> Set<String> = { [] },
        approve: @escaping (String, ActionPolicy, Any?, String?, String?) async throws -> Void,
        presentControl: @escaping (ServiceControl, Service) async -> JSONValue?,
        receiveFiles: @escaping @MainActor ([RemoteMCPFile]) async throws -> Void,
        serviceChanged: @escaping (String) -> Void,
        botControlRequired: @escaping (Service, JSONValue, Service.ServiceWebPage) -> Void = { _, _, _ in },
        begin: @escaping (String, JSONValue, String) -> UUID,
        finish: @escaping (UUID, Result<JSONValue?, Error>) -> Void,
        native: NativeServiceOperations,
        authenticationRecovery: ServiceAuthenticationRecoveryStore
    ) {
        self.serviceManager = serviceManager
        self.conversationOwner = conversationOwner
        self.resolveConversationAttachments = resolveConversationAttachments
        self.resolveService = resolveService
        self.resolveAction = resolveAction
        self.attachedDomains = attachedDomains
        self.requireApproval = approve
        self.presentControl = presentControl
        self.receiveFiles = receiveFiles
        self.serviceChanged = serviceChanged
        self.botControlRequired = botControlRequired
        self.begin = begin
        self.finish = finish
        self.native = native
        self.authenticationRecovery = authenticationRecovery
    }

    static func encodeToJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return .from(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private func tracked(_ action: String, _ args: JSONValue, purpose: String, _ body: () async throws -> JSONValue?) async throws -> JSONValue? {
        try await recorded(action, args, purpose: purpose) {
            try await requireApproval(
                action: action,
                defaultPolicy: Actions.defaultPolicy(for: action),
                args: args.toAny(),
                purpose: purpose
            )
            return try await body()
        }
    }

    private func recorded(_ name: String, _ args: JSONValue, purpose: String, _ body: () async throws -> JSONValue?) async throws -> JSONValue? {
        try Task.checkCancellation()
        let id = begin(name, args, purpose)
        do {
            let value = try await body()
            finish(id, .success(value))
            return value
        } catch {
            finish(id, .failure(error))
            throw error
        }
    }

    private func requireApproval(
        action: String,
        defaultPolicy: ActionPolicy,
        args: Any? = nil,
        purpose: String? = nil,
        prompt: String? = nil
    ) async throws {
        try await requireApproval(action, defaultPolicy, args, purpose, prompt)
    }

    func invokeAction(name: String, args: JSONValue?, purpose: String) async throws -> JSONValue? {
        let (service, actionID) = try await resolveAction(name)
        guard !service.isMCPService || serviceManager.service(domain: service.domain) === service else {
            throw RuntimeError.bridge("This MCP connection changed or was removed. Attach the current service before invoking it.")
        }
        let input = args ?? .object([:])
        let qualifiedName = service.definition.qualifiedActionName(actionID)
        guard let action = service.definition.action(actionID), let inputSchema = action.inputSchema else {
            throw Service.InvokeError.unknown(qualifiedName)
        }
        let inputViolations = JSONSchemaValidator.validate(
            input,
            against: inputSchema,
            definitions: service.definition.definitions
        )
        guard inputViolations.isEmpty else {
            throw Service.InvokeError.invalidInput(qualifiedName, inputViolations)
        }
        return try await recorded("ox.service.invoke(\(service.definition.qualifiedActionName(actionID)))", input, purpose: purpose) {
            if actionID != WebConversationContract.actionID || WebConversationContract.requiresApproval(input) {
                try await self.requireApproval(
                    action: qualifiedName,
                    defaultPolicy: action.requireApproval ? .ask : .allow,
                    args: input.toAny(),
                    purpose: purpose
                )
            }
            if service.definition.supportsConversation, actionID == WebConversationContract.actionID {
                let attachments = try await resolveConversationAttachments(input.objectValue?["attachments"]?.arrayValue ?? [])
                return try await serviceManager.invokeConversation(service: service, args: input, owner: conversationOwner, attachments: attachments)
            }
            let approve: @MainActor (String, Any?) async -> Bool = { _, _ in true }
            let result: Result<JSONValue, Error>
            if let implementation = service.apiService {
                result = await implementation.invoke(service: service, actionID: actionID, args: input, approve: approve)
            } else if let implementation = service.iOSService {
                result = await implementation.invoke(
                    service: service, actionID: actionID, args: input, purpose: purpose,
                    approve: approve,
                    nativeInvocation: { _, id, args, purpose in
                        try await self.native.invoke(service: service, actionID: id, args: args, purpose: purpose)
                    }
                )
            } else if let implementation = service.remoteMCPService {
                result = await implementation.invoke(
                    service: service, actionID: actionID, args: input,
                    approve: approve, receiveFiles: receiveFiles
                )
            } else {
                let serviceID = authenticationRecovery.consume(service, action: action)
                if serviceID != nil {
                    Log.service.info("Service.auth recovery domain=\(service.domain) action=\(actionID) scope=single-read")
                }
                result = await ServiceAuthenticationRecovery.$serviceID.withValue(serviceID) {
                    await service.invokeAction(
                        actionID,
                        args: input,
                        onBotControlRequired: { page in
                            self.botControlRequired(service, input, page)
                        },
                        approve: approve
                    )
                }
            }
            return try result.get()
        }
    }

    func validateService(domain: String, purpose: String) async throws -> JSONValue? {
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await tracked(Actions.serviceValidate, .object(["domain": .string(domain)]), purpose: purpose) {
            try await self.serviceManager.validateService(domain: domain)
            return .object(["domain": .string(domain), "valid": .bool(true)])
        }
    }

    func createService(kind: String, domain: String, endpoint: String?, transport: String?, faviconURL: JSONValue?, purpose: String) async throws -> JSONValue? {
        if kind == "mcp" {
            guard domain.isEmpty, let endpoint else {
                throw RuntimeError.bridge("ox.service.create: MCP requires endpoint and no domain; Ox assigns the service ID.")
            }
            return try await saveMCP(endpoint: endpoint, transport: transport, faviconURL: faviconURL, replacing: nil, purpose: purpose)
        }
        guard endpoint == nil, transport == nil, faviconURL == nil else {
            throw RuntimeError.bridge("ox.service.create: endpoint, transport, and faviconUrl apply only to MCP services.")
        }
        guard let serviceKind = Repository.ServiceKind(rawValue: kind), [.web, .api].contains(serviceKind) else {
            throw RuntimeError.bridge("ox.service.create: kind must be 'web', 'api', or 'mcp'")
        }
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanDomain.isEmpty else {
            throw RuntimeError.bridge("ox.service.create: web services require domain.")
        }
        let args: JSONValue = .object(["kind": .string(kind), "domain": .string(cleanDomain)])
        return try await tracked(Actions.serviceCreate, args, purpose: purpose) {
            try await self.serviceManager.createService(
                kind: serviceKind,
                id: cleanDomain,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object([
                "domain": .string(cleanDomain),
                "manifestPath": .string("services/\(kind)/\(cleanDomain)/service.json"),
                "source": .string("local"),
            ])
        }
    }

    func updateService(domain: String, fields: [String: JSONValue], purpose: String) async throws -> JSONValue? {
        let identifier = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = serviceManager.services.filter { service in
            guard let endpoint = service.definition.mcpEndpoint else { return false }
            return service.definition.name.lowercased() == identifier || endpoint.host?.lowercased() == identifier
        }
        let exact = serviceManager.service(domain: identifier)
        guard exact != nil || matches.count <= 1 else {
            throw RuntimeError.bridge("ox.service.update: multiple MCP services match '\(identifier)'; use the assigned domain from ox.service.list.")
        }
        guard let service = exact ?? matches.first else {
            throw RuntimeError.bridge("ox.service.update: service '\(identifier)' does not exist; use ox.service.create for a new service.")
        }
        let kind = Self.serviceKind(service)
        let allowed: Set<String>
        switch kind {
        case "web": allowed = ["name", "description", "baseUrl", "faviconUrl", "actions", "$defs"]
        case "api": allowed = ["name", "description", "baseUrl", "faviconUrl", "actions", "$defs", "auth"]
        case "mcp": allowed = ["endpoint", "transport", "faviconUrl"]
        default: throw RuntimeError.bridge("ox.service.update: native services are read-only.")
        }
        let unsupported = Set(fields.keys).subtracting(allowed).sorted()
        guard unsupported.isEmpty else {
            throw RuntimeError.bridge("ox.service.update: unsupported fields for \(kind): \(unsupported.joined(separator: ", ")); supported fields: \(allowed.sorted().joined(separator: ", ")).")
        }
        if let currentEndpoint = service.definition.mcpEndpoint {
            guard service.isLocalService else {
                throw RuntimeError.bridge("ox.service.update: repository MCP definitions are read-only; copy the service to Local before editing it.")
            }
            return try await saveMCP(
                endpoint: fields["endpoint"]?.stringValue ?? currentEndpoint.absoluteString,
                transport: fields["transport"]?.stringValue ?? service.definition.mcpTransport?.rawValue,
                faviconURL: fields["faviconUrl"],
                replacing: service,
                purpose: purpose
            )
        }
        guard !fields.isEmpty else {
            throw RuntimeError.bridge("ox.service.update: provide at least one manifest field for a Local \(kind) service.")
        }
        let sourceKind: ServicesMount.Kind = kind == "api" ? .api : .web
        var args = fields
        args["domain"] = .string(service.domain)
        return try await tracked(Actions.serviceUpdate, .object(args), purpose: purpose) {
            try await self.serviceManager.updateServiceManifest(kind: sourceKind, domain: service.domain, fields: fields)
            return .object([
                "domain": .string(service.domain),
                "kind": .string(kind),
                "manifestPath": .string("services/\(kind)/\(service.domain)/service.json"),
                "source": .string("local"),
                "reloadRequired": .bool(true),
            ])
        }
    }

    private func saveMCP(endpoint: String, transport: String?, faviconURL: JSONValue?, replacing: Service?, purpose: String) async throws -> JSONValue? {
        let endpoint = try RemoteMCPService.endpoint(endpoint)
        guard transport == nil || transport == "auto" || RemoteMCPTransport(rawValue: transport!) != nil else {
            throw RuntimeError.bridge("MCP transport must be 'auto', 'streamable-http', or 'sse'.")
        }
        let resolvedFaviconURL: URL?
        if let faviconURL {
            guard faviconURL == .null || faviconURL.stringValue != nil else {
                throw RuntimeError.bridge("MCP faviconUrl must be an HTTPS URL or null.")
            }
            resolvedFaviconURL = try ServiceDefinition.faviconURL(faviconURL.stringValue)
        } else {
            resolvedFaviconURL = replacing?.definition.faviconURL
        }
        let resolvedTransport = transport.flatMap(RemoteMCPTransport.init(rawValue:))
        let action = replacing == nil ? Actions.serviceCreate : Actions.serviceUpdate
        var fields: [String: JSONValue] = [
            "kind": .string("mcp"),
            "endpoint": .string(endpoint.absoluteString),
            "transport": .string(transport ?? "auto"),
        ]
        if let faviconURL { fields["faviconUrl"] = faviconURL }
        if let replacing { fields["domain"] = .string(replacing.domain) }
        let args: JSONValue = .object(fields)
        return try await tracked(action, args, purpose: purpose) {
            let service = try await self.serviceManager.connectRemoteMCP(
                endpoint.absoluteString,
                transport: resolvedTransport,
                faviconURL: resolvedFaviconURL,
                replacing: replacing
            )
            if let replacing { serviceChanged(replacing.domain) }
            return try serviceSnapshot(service)
        }
    }

    func copyService(domain: String, purpose: String) async throws -> JSONValue? {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let service = serviceManager.service(domain: cleanDomain) else {
            throw RuntimeError.bridge("ox.service.copy: service '\(cleanDomain)' does not exist.")
        }
        let kind = Self.serviceKind(service)
        let args: JSONValue = .object(["domain": .string(cleanDomain)])
        return try await tracked(Actions.serviceCopy, args, purpose: purpose) {
            try await self.serviceManager.copyServiceToLocal(
                domain: cleanDomain,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object([
                "domain": .string(cleanDomain),
                "manifestPath": .string("services/\(kind)/\(cleanDomain)/service.json"),
                "source": .string("local"),
            ])
        }
    }

    func deleteService(domain: String, purpose: String) async throws -> JSONValue? {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let currentService = serviceManager.service(domain: cleanDomain)
        var fields: [String: JSONValue] = ["domain": .string(cleanDomain)]
        if let endpoint = currentService?.definition.mcpEndpoint {
            fields["endpoint"] = .string(endpoint.absoluteString)
        }
        let args: JSONValue = .object(fields)
        return try await tracked(Actions.serviceDelete, args, purpose: purpose) {
            if let currentService, currentService.isMCPService {
                try await self.serviceManager.removeRemoteMCP(currentService)
                serviceChanged(cleanDomain)
                return .object(["domain": .string(cleanDomain), "kind": .string("mcp"), "deleted": .bool(true)])
            }
            let kind = try await self.serviceManager.deleteLocalService(
                domain: cleanDomain,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            let replacement = self.serviceManager.service(domain: cleanDomain)
            serviceChanged(cleanDomain)
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

    func repositoryConflicts(service: String?, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(service.map { ["service": .string($0)] } ?? [:])
        return try await tracked(Actions.repositoryConflicts, args, purpose: purpose) {
            let conflicts = self.serviceManager.repositoryConflicts.filter { service == nil || $0.serviceID == service }
            return .object([
                "conflicts": .array(conflicts.prefix(100).map { conflict in
                    .object([
                        "service": .string(conflict.serviceID),
                        "selectedRepository": conflict.selectedRepositoryID.map(JSONValue.string) ?? .null,
                        "candidates": .array(conflict.candidates.map { candidate in
                            .object(["repository": .string(candidate.repositoryID), "name": .string(candidate.repositoryName)])
                        }),
                    ])
                }),
                "truncated": .bool(conflicts.count > 100),
            ])
        }
    }

    func resolveRepositoryConflict(service: String, repository: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["service": .string(service), "repository": .string(repository)])
        return try await tracked(Actions.repositoryResolve, args, purpose: purpose) {
            try await self.serviceManager.resolveConflict(
                serviceID: service,
                repositoryID: repository,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object([
                "service": .string(service),
                "selectedRepository": .string(repository),
                "reloadRequired": .bool(self.attachedDomains().contains(service)),
            ])
        }
    }

    func connectRepository(origin: String, purpose: String) async throws -> JSONValue? {
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let mounted = origin.hasPrefix("files/")
        if !mounted {
            guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else {
                throw RuntimeError.bridge("ox.repository.connect: use a public HTTPS Git URL without credentials or a fragment, or files/<grant-id>[/subfolder]")
            }
        }
        return try await tracked(
            Actions.repositoryConnect,
            .object(["origin": .string(origin)]),
            purpose: purpose
        ) {
            let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            let repository: Repository.Descriptor
            if mounted {
                repository = try await self.serviceManager.connectMountedRepository(path: origin, locale: locale)
            } else {
                guard let url = URL(string: origin) else { throw RuntimeError.bridge("Invalid repository origin") }
                repository = try await self.serviceManager.connectRepository(from: url, locale: locale)
            }
            return .object([
                "id": .string(repository.id),
                "name": .string(repository.name),
                "origin": .string(origin),
                "serviceCount": .int(repository.serviceCount),
                "skillCount": .int(repository.skills.count),
                "connected": .bool(true),
            ])
        }
    }

    func disconnectRepository(repository: String, purpose: String) async throws -> JSONValue? {
        guard let selected = serviceManager.repositories.first(where: {
            $0.id == repository && [.remote, .mounted].contains($0.provenance)
        }) else {
            throw RuntimeError.bridge("ox.repository.disconnect: select a remote or mounted repository ID from ox.repository.list")
        }
        let args: JSONValue = .object([
            "id": .string(selected.id),
            "name": .string(selected.name),
            "origin": selected.origin.map { .string($0.absoluteString) } ?? .null,
            "serviceCount": .int(selected.serviceCount),
        ])
        return try await tracked(Actions.repositoryDisconnect, args, purpose: purpose) {
            try await self.serviceManager.disconnectRepository(
                selected.id,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object(["id": .string(selected.id), "disconnected": .bool(true)])
        }
    }

    func enableRepository(repository: String, enabled: Bool, purpose: String) async throws -> JSONValue? {
        guard let selected = serviceManager.repositories.first(where: { $0.id == repository }) else {
            throw RuntimeError.bridge("ox.repository.enable: select an existing repository ID from ox.repository.list")
        }
        let args: JSONValue = .object([
            "repository": .string(selected.id),
            "name": .string(selected.name),
            "enabled": .bool(enabled),
        ])
        return try await tracked(Actions.repositoryEnable, args, purpose: purpose) {
            try Task.checkCancellation()
            let previous = self.serviceManager.repositories.first(where: { $0.id == repository })?.isEnabled
            let updated = try await self.serviceManager.setRepositoryEnabled(
                repository,
                enabled: enabled,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object([
                "id": .string(updated.id),
                "enabled": .bool(updated.isEnabled),
                "changed": .bool(previous != updated.isEnabled),
                "serviceCount": .int(updated.serviceCount),
                "skillCount": .int(updated.skills.count),
            ])
        }
    }

    func syncRepository(repository: String, purpose: String) async throws -> JSONValue? {
        guard let selected = serviceManager.repositories.first(where: {
            $0.id == repository && [.remote, .mounted].contains($0.provenance)
        }) else {
            throw RuntimeError.bridge("ox.repository.sync: select a remote or mounted repository ID from ox.repository.list")
        }
        let args: JSONValue = .object([
            "id": .string(selected.id),
            "name": .string(selected.name),
            "serviceCount": .int(selected.serviceCount),
        ])
        return try await tracked(Actions.repositorySync, args, purpose: purpose) {
            let synced = try await self.serviceManager.syncRepository(
                selected.id,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object([
                "id": .string(synced.id),
                "name": .string(synced.name),
                "serviceCount": .int(synced.serviceCount),
                "skillCount": .int(synced.skills.count),
                "synced": .bool(true),
            ])
        }
    }

    func inspectService(domain: String, actions: [String]?, purpose: String) async throws -> JSONValue? {
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
        let service = try await resolveService(cleanDomain)
        guard await service.loadManifest(reason: .inspect) != nil else {
            throw RuntimeError.bridge("ox.service.inspect: service '\(cleanDomain)' capabilities are unavailable; authorize or retry the service first.")
        }
        var fields: [String: JSONValue] = ["domain": .string(cleanDomain)]
        if let actions { fields["actions"] = .array(actions.map(JSONValue.string)) }
        return try await tracked(Actions.serviceInspect, .object(fields), purpose: purpose) {
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
            if service.supportsAuthentication {
                result["signIn"] = OxActions.signInDetail
            }
            if let botControl = OxActions.botControlDetail(definition: definition) {
                result["botControl"] = botControl
            }
            if let payment = OxActions.paymentDetail(definition: definition) {
                result["payment"] = payment
            }
            return .object(result)
        }
    }

    func listServices(kind: String?, purpose: String) async throws -> JSONValue? {
        if let kind, !["web", "api", "ios", "mcp"].contains(kind) {
            throw RuntimeError.bridge("ox.service.list: kind must be 'web', 'api', 'ios', or 'mcp'")
        }
        let args: JSONValue = .object(kind.map { ["kind": .string($0)] } ?? [:])
        return try await tracked(Actions.serviceList, args, purpose: purpose) {
            guard serviceManager.monoRepositoryState == .ready else {
                throw RuntimeError.bridge("ox.service.list: Ox Server is still loading services. Try again later.")
            }
            let snapshots = try serviceManager.services
                .filter { kind == nil || Self.serviceKind($0) == kind }
                .sorted { $0.domain < $1.domain }
                .map { try self.serviceSnapshot($0) }
            Log.session.info("bridge.service.list kind=\(kind ?? "all") count=\(snapshots.count)")
            return .array(snapshots)
        }
    }

    func findServices(query: String, purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.serviceFind, .object(["query": .string(query)]), purpose: purpose) {
            guard serviceManager.monoRepositoryState == .ready else {
                Log.session.info("bridge.service.find unavailable monoRepository=loading chars=\(query.count)")
                throw RuntimeError.bridge("ox.service.find: Ox Server is still loading services. Continue without service discovery or try again later.")
            }
            return try await serviceSuggestions(query: query)
        }
    }

    func serviceSuggestions(query: String) async throws -> JSONValue {
        guard serviceManager.monoRepositoryState == .ready else {
            Log.session.info("bridge.service.suggestions unavailable monoRepository=loading chars=\(query.count)")
            return .null
        }
        let matches = await serviceManager.search(query, filter: .all).prefix(Self.maximumFindResults)
        let attached = attachedDomains()
        let results = matches.map {
            ServiceFindResult(
                match: $0,
                attached: attached.contains($0.service.domain),
                kind: Self.serviceKind($0.service)
            )
        }
        Log.session.info("bridge.service.suggestions chars=\(query.count) hits=\(results.count)")
        return try Self.encodeToJSON(results)
    }

    func signInService(domain: String, purpose: String) async throws -> JSONValue? {
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("ox.service.signIn: requires a non-empty domain")
        }
        let service = try await resolveService(domain)
        guard service.supportsAuthentication else {
            throw RuntimeError.bridge("ox.service.signIn: \(domain) declares no sign-in handoff")
        }
        return try await tracked(Actions.serviceSignIn, .object(["domain": .string(domain)]), purpose: purpose) {
            authenticationRecovery.clear()
            await service.checkAccess(policy: .current, reason: .modelSignIn)
            if service.signInState.isAuthenticated {
                Log.session.info("bridge.service.signIn already authenticated domain=\(domain) auth=\(service.signInState.rawValue)")
                return service.accessResult()
            }
            let control = ServiceControl.signIn(domain: domain, serviceName: service.title)
            Log.session.info("bridge.service.signIn handoff domain=\(domain) auth=\(service.signInState.rawValue)")
            guard let result = await presentControl(control, service) else {
                throw OxFunctionError(code: "handoff_incomplete", message: "ox.service.signIn: the user cancelled or sign-in failed.", recovery: "Do not reopen sign-in automatically. Ask the user whether to continue, then inspect the service's sign-in state before trying again.")
            }
            try Task.checkCancellation()
            if result.objectValue?["completion"]?.stringValue == "acknowledged", service.isWebService {
                authenticationRecovery.acknowledge(service)
                return result
            }
            return service.accessResult()
        }
    }

    func solveService(domain: String, args: JSONValue, purpose: String) async throws -> JSONValue? {
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("ox.service.solve: requires a non-empty domain")
        }
        guard args.objectValue != nil else {
            throw RuntimeError.bridge("ox.service.solve: args must be an object")
        }
        let service = try await resolveService(domain)
        guard service.supportsBotControl else {
            throw RuntimeError.bridge("ox.service.solve: \(domain) does not support human verification")
        }
        return try await tracked(Actions.serviceSolve, .object(["domain": .string(domain), "args": args]), purpose: purpose) {
            let control = ServiceControl.botControl(domain: domain, serviceName: service.title, args: args)
            Log.session.info("bridge.service.solve handoff domain=\(domain)")
            guard await presentControl(control, service) != nil else {
                throw OxFunctionError(code: "handoff_incomplete", message: "ox.service.solve: the user cancelled or verification failed.", recovery: "Do not reopen verification automatically. Ask the user whether to continue and inspect the service state before trying again.")
            }
            return .null
        }
    }

    func payService(domain: String, args: JSONValue, purpose: String) async throws -> JSONValue? {
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("ox.service.pay: requires a non-empty domain")
        }
        guard args.objectValue != nil else {
            throw RuntimeError.bridge("ox.service.pay: args must be an object")
        }
        let service = try await resolveService(domain)
        guard service.definition.action(Manifest.PAYMENT_URL_ACTION_ID, includingStandard: true) != nil,
              service.definition.action(Manifest.PAYMENT_STATE_ACTION_ID, includingStandard: true) != nil else {
            throw RuntimeError.bridge("ox.service.pay: \(domain) declares no payment handoff")
        }
        return try await tracked(Actions.servicePayment, .object(["domain": .string(domain), "args": args]), purpose: purpose) {
            let control = ServiceControl.payment(domain: domain, serviceName: service.title, args: args)
            Log.session.info("bridge.service.payment handoff domain=\(domain)")
            guard let result = await presentControl(control, service) else {
                throw OxFunctionError(code: "handoff_incomplete", message: "ox.service.pay: the user cancelled or checkout did not complete.", recovery: "Do not reopen checkout automatically. Inspect the transaction status to avoid duplicate payment, and ask the user whether to continue.")
            }
            return result
        }
    }

    private func serviceSnapshot(_ service: Service) throws -> JSONValue {
        var fields = try Self.serviceSnapshotFields(service, attached: attachedDomains().contains(service.domain))
        if service.definition.mcpEndpoint != nil {
            fields["faviconUrl"] = service.definition.faviconURL.map { .string($0.absoluteString) } ?? .null
        }
        return .object(fields)
    }

    static func serviceSnapshotFields(_ service: Service, attached: Bool) throws -> [String: JSONValue] {
        guard case .object(var fields) = try encodeToJSON(service.snapshot(attached: attached)) else {
            throw RuntimeError.bridge("service snapshot is not an object")
        }
        fields["kind"] = .string(serviceKind(service))
        if let endpoint = service.definition.mcpEndpoint {
            fields["endpoint"] = .string(endpoint.absoluteString)
            fields["transport"] = .string(service.definition.mcpTransport?.rawValue ?? "auto")
        }
        if case .repository(let id, let provenance) = service.definition.source {
            fields["repository"] = .string(id)
            fields["repositoryProvenance"] = .string(provenance.rawValue)
        }
        return fields
    }

    static func serviceKind(_ service: Service) -> String {
        if service.isIOSService { return "ios" }
        if service.isAPIService { return "api" }
        if service.isMCPService { return "mcp" }
        return "web"
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
        let matchedAction: MatchedAction?

        init(match: ServiceManager.ServiceMatch, attached: Bool, kind: String) {
            let snapshot = match.service.snapshot(attached: attached)
            domain = snapshot.domain
            self.kind = kind
            manifestPath = "services/\(kind)/\(snapshot.domain)/service.json"
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
            matchedAction = match.matchedActionID.flatMap { id in
                match.matchedAction.map { MatchedAction(id: id, label: $0) }
            }
        }
    }
}

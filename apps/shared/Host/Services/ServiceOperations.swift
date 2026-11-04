import Foundation
import WebKit

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
    let begin: (String, JSONValue, String) -> UUID
    let finish: (UUID, Result<JSONValue?, Error>) -> Void
    let native: NativeServiceOperations

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
        begin: @escaping (String, JSONValue, String) -> UUID,
        finish: @escaping (UUID, Result<JSONValue?, Error>) -> Void,
        native: NativeServiceOperations
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
        self.begin = begin
        self.finish = finish
        self.native = native
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

    func invokeAction(name: String, args: JSONValue?, session: JSONValue? = nil, pageURL: String? = nil, purpose: String) async throws -> JSONValue? {
        let (service, actionID) = try await resolveAction(name)
        return try await invokeAction(service: service, actionID: actionID, args: args, session: session, pageURL: pageURL, purpose: purpose)
    }

    func invokeAction(service: Service, actionID: String, args: JSONValue?, session: JSONValue? = nil, pageURL: String? = nil, purpose: String) async throws -> JSONValue? {
        guard !service.isMCPService || serviceManager.service(domain: service.domain) === service else {
            throw RuntimeError.bridge("This MCP connection changed or was removed. Attach the current service before invoking it.")
        }
        if service.isMCPService, await service.loadManifest(reason: .invoke) == nil {
            throw RuntimeError.bridge("Service capabilities are unavailable; use ox.service.requestAccess if authorization is required")
        }
        let input = args ?? .object([:])
        if session != nil || pageURL != nil {
            guard service.isWebService, let baseURL = service.definition.baseURL else {
                throw RuntimeError.bridge("Session routing is supported only for web services")
            }
            _ = try service.executionURL(defaultURL: baseURL, session: session, pageURL: pageURL)
        }
        let recordedInput: JSONValue = session == nil && pageURL == nil ? input : .object([
            "input": input,
            "session": session ?? .null,
            "pageUrl": pageURL.map(JSONValue.string) ?? .null,
        ])
        let qualifiedName = service.definition.qualifiedActionName(actionID)
        guard let action = service.definition.action(actionID), let inputSchema = action.inputSchema else {
            throw Service.InvokeError.unknown(qualifiedName)
        }
        if WebSessionContract.isEnabled(service.definition), action.requireAuth, session == nil {
            throw OxFunctionError(code: "authentication_required", message: "Select a logged-in session before invoking this action. No action was executed.", recovery: "Use the service's checkAccess contract to discover sessions and select the intended account/tenant. Request access only if needed; never invent a descriptor.")
        }
        let inputViolations = JSONSchemaValidator.validate(
            input,
            against: inputSchema,
            definitions: service.definition.definitions
        )
        guard inputViolations.isEmpty else {
            throw Service.InvokeError.invalidInput(qualifiedName, inputViolations)
        }
        return try await recorded("ox.service.invoke(\(service.definition.qualifiedActionName(actionID)))", recordedInput, purpose: purpose) {
            if actionID != WebConversationContract.actionID || WebConversationContract.requiresApproval(input) {
                try await self.requireApproval(
                    action: qualifiedName,
                    defaultPolicy: action.requireApproval ? .ask : .allow,
                    args: recordedInput.toAny(),
                    purpose: purpose
                )
            }
            if service.definition.supportsConversation, actionID == WebConversationContract.actionID {
                let attachments = try await resolveConversationAttachments(input.objectValue?["attachments"]?.arrayValue ?? [])
                return try await serviceManager.invokeConversation(service: service, args: input, owner: conversationOwner, attachments: attachments)
            }
            let approve: @MainActor (String, Any?) async -> Bool = { name, args in
                guard service.isWebService,
                      name == service.definition.qualifiedActionName(WebSessionContract.listAction),
                      name != qualifiedName else { return true }
                do {
                    try await self.requireApproval(action: name, defaultPolicy: .allow, args: args, purpose: purpose)
                    return true
                } catch {
                    return false
                }
            }
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
                result = await service.invokeAction(
                    actionID,
                    args: input,
                    session: session,
                    pageURL: pageURL,
                    approve: approve
                )
            }
            let value = try result.get()
            if WebSessionContract.isEnabled(service.definition), actionID == WebSessionContract.loginAction {
                try await self.presentLogin(service: service, actionID: actionID, input: input, session: session, pageURL: pageURL)
            }
            return value
        }
    }

    private func presentLogin(service: Service, actionID: String, input: JSONValue, session: JSONValue?, pageURL: String?) async throws {
        guard let action = await service.resolvedAction(actionID, args: input, session: session, pageURL: pageURL),
              let lease = try await serviceManager.actionScheduler.reserveForPresentation(action, allowUnready: true) else {
            throw OxFunctionError(code: "page_unavailable", message: "Login preparation has no idle live page.", recovery: "Inspect the page and preparation failure before retrying login.")
        }
        defer { lease.release() }
        guard lease.page.page.url != nil else { throw Service.EvalError.notReady }
        let handoff = ServiceHandoffSession(
            service: service,
            servicePage: lease.page,
            title: service.title,
            navigationTitle: String(localized: "Log in")
        )
        Log.service.info("Service.login presenting domain=\(service.domain) page=\(lease.page.logLabel)")
        let outcome = await native.presentations.serviceHandoff.present(session: handoff)
        try Task.checkCancellation()
        guard outcome == .completed, lease.isActive else {
            throw OxFunctionError(code: "handoff_incomplete", message: "Login interaction was cancelled or unavailable.", recovery: "Do not reopen automatically. Ask the user whether to continue; the page is preserved.")
        }
        if lease.page.page.url?.host.map(service.isServiceHost) != true {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            while lease.isActive, lease.page.navigationPhase.load != nil, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            guard lease.isActive,
                  await service.navigate(action.baseURL, in: lease.page) != nil else {
                throw OxFunctionError(code: "page_unavailable", message: "The login interaction finished, but its target page could not be resumed.", recovery: "Inspect the preserved page. Do not assume authentication succeeded or repeat a mutation.")
            }
        }
        Log.service.info("Service.login acknowledged domain=\(service.domain) page=\(lease.page.logLabel) verified=false")
    }

    func validateService(domain: String, purpose: String) async throws -> JSONValue? {
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await tracked(Actions.serviceValidate, .object(["domain": .string(domain)]), purpose: purpose) {
            try await self.serviceManager.validateService(domain: domain)
            return .object(["domain": .string(domain), "valid": .bool(true)])
        }
    }

    func createService(kind: String, domain: String, endpoint: String?, transport: String?, faviconURL: JSONValue?, purpose: String) async throws -> JSONValue? {
        guard kind == "mcp", domain.isEmpty, let endpoint else {
            throw RuntimeError.bridge("ox.service.create: MCP requires endpoint and no domain. Create web/API source with ox.fs under repositories/local/.")
        }
        return try await saveMCP(endpoint: endpoint, transport: transport, faviconURL: faviconURL, replacing: nil, purpose: purpose)
    }

    func updateService(domain: String, fields: [String: JSONValue], purpose: String) async throws -> JSONValue? {
        let identifier = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = serviceManager.services.filter { service in
            guard let endpoint = service.definition.mcpEndpoint else { return false }
            return service.title.lowercased() == identifier || endpoint.host?.lowercased() == identifier
        }
        let exact = serviceManager.service(domain: identifier)
        guard exact != nil || matches.count <= 1 else {
            throw RuntimeError.bridge("ox.service.update: multiple MCP services match '\(identifier)'; use the assigned domain from the saved repositories/local/mcp/<domain>/service.json definition.")
        }
        guard let service = exact ?? matches.first else {
            throw RuntimeError.bridge("ox.service.update: service '\(identifier)' does not exist; use ox.service.create for a new service.")
        }
        let name: String?
        if let value = fields["name"] {
            guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw RuntimeError.bridge("ox.service.update: name must be a nonempty string.")
            }
            name = text
        } else {
            name = nil
        }
        var fields = fields
        fields.removeValue(forKey: "name")
        if fields.isEmpty, let name {
            let args: JSONValue = .object(["domain": .string(service.domain), "name": .string(name)])
            return try await tracked(Actions.serviceUpdate, args, purpose: purpose) {
                self.serviceManager.renameService(service, to: name)
                return try self.serviceSnapshot(service)
            }
        }
        let kind = Self.serviceKind(service)
        let allowed: Set<String>
        switch kind {
        case "web", "api": allowed = []
        case "mcp": allowed = ["endpoint", "transport", "faviconUrl"]
        default: throw RuntimeError.bridge("ox.service.update: native services support only name.")
        }
        let unsupported = Set(fields.keys).subtracting(allowed).sorted()
        guard unsupported.isEmpty else {
            throw RuntimeError.bridge("ox.service.update: unsupported fields for \(kind): \(unsupported.joined(separator: ", ")); supported fields: \(allowed.union(["name"]).sorted().joined(separator: ", ")).")
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
                name: name,
                purpose: purpose
            )
        }
        throw RuntimeError.bridge("ox.service.update: provide a name, or edit Local source with ox.fs under repositories/local/.")
    }

    private func saveMCP(endpoint: String, transport: String?, faviconURL: JSONValue?, replacing: Service?, name: String? = nil, purpose: String) async throws -> JSONValue? {
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
        if let name { fields["name"] = .string(name) }
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
            if let name { self.serviceManager.renameService(service, to: name) }
            if let replacing { serviceChanged(replacing.domain) }
            return try serviceSnapshot(service)
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

    func repositoryConflicts(service: String?, compare: Bool, purpose: String) async throws -> JSONValue? {
        guard !compare || service != nil else {
            throw RuntimeError.bridge("Source comparison requires an exact service from ox.repository.conflicts.")
        }
        var fields = service.map { ["service": JSONValue.string($0)] } ?? [:]
        fields["compare"] = .bool(compare)
        return try await tracked(Actions.repositoryConflicts, .object(fields), purpose: purpose) {
            let conflicts = self.serviceManager.repositoryConflicts.filter { service == nil || $0.serviceID == service }
            var result: [String: JSONValue] = [
                "conflicts": .array(conflicts.prefix(100).map { conflict in
                    .object([
                        "service": .string(conflict.serviceID),
                        "selectedRepository": conflict.selectedRepositoryID.map(JSONValue.string) ?? .null,
                        "candidates": .array(conflict.candidates.map { candidate in
                            .object(["repository": .string(candidate.repositoryID), "name": .string(candidate.repositoryName),
                                "path": .string(candidate.path)])
                        }),
                    ])
                }),
                "truncated": .bool(conflicts.count > 100),
            ]
            if compare, let service {
                result["comparison"] = try await self.serviceManager.compareServiceSources(service)
            }
            return .object(result)
        }
    }

    func resolveRepositoryConflict(service: String, repository: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["service": .string(service), "repository": .string(repository)])
        return try await tracked(Actions.repositoryResolve, args, purpose: purpose) {
            let changed = try await self.serviceManager.resolveConflict(
                serviceID: service,
                repositoryID: repository,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            return .object([
                "service": .string(service),
                "selectedRepository": .string(repository),
                "reloadRequired": .bool(changed && self.attachedDomains().contains(service)),
            ])
        }
    }

    func connectRepository(origin: String, purpose: String) async throws -> JSONValue? {
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let mounted = origin.hasPrefix("mounts/") || origin.hasPrefix("files/")
        if !mounted {
            guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else {
                throw RuntimeError.bridge("ox.repository.connect: use a public HTTPS Git URL without credentials or a fragment, or mounts/<grant-id>[/subfolder]")
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
        let service = try await resolveService(cleanDomain)
        return try await inspectService(service: service, actions: actions, purpose: purpose)
    }

    func inspectService(service: Service, actions: [String]?, purpose: String) async throws -> JSONValue? {
        let cleanDomain = service.domain
        if let actions {
            guard (1...10).contains(actions.count),
                  actions.allSatisfy({ !$0.isEmpty && $0.count <= 500 }),
                  Set(actions).count == actions.count else {
                throw RuntimeError.bridge("ox.service.inspect: actions must contain 1-10 unique action IDs of 1-500 characters")
            }
        }
        var fields: [String: JSONValue] = ["domain": .string(cleanDomain)]
        if let actions { fields["actions"] = .array(actions.map(JSONValue.string)) }
        return try await tracked(Actions.serviceInspect, .object(fields), purpose: purpose) {
            let available = await service.loadManifest(reason: .inspect) != nil
            guard available || (service.isMCPService && actions == nil) else {
                throw RuntimeError.bridge("ox.service.inspect: service '\(cleanDomain)' capabilities are unavailable; use requestAccess if authorization is required, otherwise inspect the source or connection error.")
            }
            let definition = service.definition
            let index = available ? OxActions.index(definition: definition) : [:]
            var details = available ? Dictionary(uniqueKeysWithValues: definition.exposedActions.map { action in
                (action.id, index[definition.qualifiedActionName(action.id)] ?? .object([:]))
            }) : [:]
            var fullContracts = false
            if available, actions != nil || definition.exposedActions.count <= 10 {
                let schemas = try Dictionary(uniqueKeysWithValues: (actions ?? definition.exposedActions.map(\.id)).map { id in
                    guard let detail = OxActions.detail(definition: definition, id: id) else {
                        throw RuntimeError.bridge("ox.service.inspect: unknown exposed action '\(cleanDomain):\(id)'.")
                    }
                    return (id, detail)
                })
                if actions != nil || JSONValue.object(schemas).jsonString().utf8.count <= 32 * 1024 {
                    details = schemas
                    fullContracts = true
                }
            }
            Log.session.info("bridge.service.inspect domain=\(cleanDomain) schemas=\(fullContracts) count=\(details.count)")
            var result: [String: JSONValue] = [
                "service": try self.serviceSnapshot(service),
                "actions": .object(details),
                "access": OxActions.accessDetail(service: service),
                "capabilitiesAvailable": .bool(available),
            ]
            if !available, case .unavailable(let error) = service.capabilityState {
                result["capabilityError"] = .string(error)
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
            let services = Dictionary(uniqueKeysWithValues: serviceManager.services.map { ($0.domain, $0) })
            var entries = try services.values.filter { $0.isIOSService || $0.isMCPService }.map { service in
                var fields = try Self.serviceSnapshotFields(service, attached: attachedDomains().contains(service.domain))
                fields["manifestPath"] = .string(Self.manifestPath(service))
                return JSONValue.object(fields)
            }
            for entry in try await serviceManager.serviceSourceListings() {
                guard var fields = entry.objectValue, let domain = fields["domain"]?.stringValue else { continue }
                fields["login"] = .string("unknown")
                fields["saved"] = .bool(serviceManager.savedDomains.contains(domain))
                fields["attached"] = .bool(attachedDomains().contains(domain))
                if fields["validationError"] == nil, let service = services[domain] {
                    fields.merge(try Self.serviceSnapshotFields(service, attached: attachedDomains().contains(domain))) { current, _ in current }
                }
                entries.append(.object(fields))
            }
            let snapshots = entries
                .filter { kind == nil || $0.objectValue?["kind"]?.stringValue == kind }
                .sorted { ($0.objectValue?["domain"]?.stringValue ?? "") < ($1.objectValue?["domain"]?.stringValue ?? "") }
            Log.session.info("bridge.service.list kind=\(kind ?? "all") count=\(snapshots.count) invalid=\(snapshots.filter { $0.objectValue?["validationError"] != nil }.count)")
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

    func showServicePage(name: String, args: JSONValue?, session: JSONValue? = nil, pageURL: String? = nil, purpose: String) async throws -> JSONValue? {
        let (service, actionID) = try await resolveAction(name)
        let input = args ?? .object([:])
        guard service.isWebService,
              let action = await service.resolvedAction(actionID, args: input, session: session, pageURL: pageURL) else {
            throw RuntimeError.bridge("ox.service.showPage: requires a web service action")
        }
        return try await tracked(Actions.serviceShowPage, .object(["name": .string(name), "input": input, "session": session ?? .null, "pageUrl": pageURL.map(JSONValue.string) ?? .null]), purpose: purpose) {
            guard let lease = try await serviceManager.actionScheduler.reserveForPresentation(action, allowUnready: true) else {
                throw OxFunctionError(code: "page_unavailable", message: "ox.service.showPage: this action has no idle live page.", recovery: "Wait for active actions to finish. Use the name and input of the action whose page you want to show. This function never opens a replacement page or reruns the action.")
            }
            defer { lease.release() }
            guard lease.page.page.url != nil else { throw Service.EvalError.notReady }
            try native.presentServicePage(service, page: lease.page)
            Log.service.info("Service.showPage shown domain=\(service.domain) action=\(actionID) session=\(lease.page.logLabel)")
            return .object(["shown": .bool(true)])
        }
    }

    func checkServiceAccess(domain: String, pageURL: String? = nil, purpose: String) async throws -> JSONValue? {
        let service = try await resolveService(domain)
        guard pageURL == nil || service.isWebService else {
            throw OxFunctionError(code: "invalid_argument", message: "pageUrl is supported only for website access checks.", recovery: "Use the applicable input schema from inspect.access.checkAccess.")
        }
        guard serviceManager.actionPolicy(for: Actions.serviceCheckAccess, default: .allow) == .allow else {
            throw OxFunctionError(code: "permission_denied", message: "checkAccess is not allowed by Action policy; no access check was performed.", recovery: "Stop. Do not bypass Ask or Block through another discovery path.")
        }
        if service.isWebService {
            guard WebSessionContract.isEnabled(service.definition) else {
                throw OxFunctionError(code: "not_supported", message: "This website declares no session discovery; missing support does not establish signed-out state.", recovery: "Inspect its actions. If authenticated work is required, use Evolve to implement discovery from real website evidence.")
            }
            let name = service.definition.qualifiedActionName(WebSessionContract.listAction)
            let defaultPolicy: ActionPolicy = service.definition.action(WebSessionContract.listAction)?.requireApproval == true ? .ask : .allow
            guard serviceManager.actionPolicy(for: name, default: defaultPolicy) == .allow else {
                throw OxFunctionError(code: "permission_denied", message: "listSessions requires approval or is blocked; no discovery was performed.", recovery: "Stop. checkAccess never prompts or bypasses the discovery Action policy.")
            }
            return try await recorded(Actions.serviceCheckAccess, .object(["domain": .string(domain)]), purpose: purpose) {
                let result = await service.invokeAction(WebSessionContract.listAction, args: .object([:]), pageURL: pageURL, approve: { name, _ in
                    self.serviceManager.actionPolicy(for: name, default: defaultPolicy) == .allow
                })
                return .object(["domain": .string(domain), "kind": .string("web"), "evidence": .string("listSessions"), "sessions": try result.get()])
            }
        }
        return try await recorded(Actions.serviceCheckAccess, .object(["domain": .string(domain)]), purpose: purpose) {
            let auth: Service.Auth
            let evidence: String
            if let api = service.apiService {
                auth = try api.authorization.configuredAccess()
                evidence = "credentialConfiguration"
            } else if let mcp = service.remoteMCPService {
                auth = try await mcp.checkAccess()
                evidence = "mcpConnection"
            } else {
                auth = try await service.readAccess()
                evidence = "devicePermission"
            }
            try Task.checkCancellation()
            service.setAuth(auth)
            let state: String
            switch auth {
            case .notRequired: state = "notRequired"
            case .authorized: state = "authorized"
            case .authorizationRequired: state = "authorizationRequired"
            case .notAuthorized: state = "denied"
            case .observed(let observation): state = observation.value == .signedIn ? "configured" : "notConfigured"
            default: throw RuntimeError.bridge("Access could not be determined")
            }
            return .object(["domain": .string(domain), "kind": .string(Self.serviceKind(service)), "state": .string(state), "evidence": .string(evidence)])
        }
    }

    func requestServiceAccess(domain: String, input: JSONValue?, pageURL: String?, purpose: String) async throws -> JSONValue? {
        let service = try await resolveService(domain)
        if service.isWebService {
            guard WebSessionContract.isEnabled(service.definition) else {
                throw OxFunctionError(code: "not_supported", message: "This website declares no access request.", recovery: "Inspect its actions. If authenticated work is required, use Evolve to implement login and session discovery from real website evidence.")
            }
            _ = try await invokeAction(
                name: service.definition.qualifiedActionName(WebSessionContract.loginAction),
                args: input, pageURL: pageURL, purpose: purpose
            )
            return .object([
                "domain": .string(service.domain), "kind": .string("web"),
                "completed": .bool(true), "completion": .string("acknowledged"),
            ])
        }
        guard input == nil, pageURL == nil else {
            throw OxFunctionError(code: "invalid_argument", message: "input and pageUrl are supported only for website access requests.", recovery: "Use the applicable input schema from inspect.access.requestAccess.")
        }
        guard let value = try await loginService(domain: domain, purpose: purpose), case .object(var result) = value else {
            throw RuntimeError.bridge("Access request returned no completion evidence")
        }
        result.removeValue(forKey: "signedIn")
        if service.isAPIService {
            switch result["state"]?.stringValue {
            case "signedIn": result["state"] = .string("configured")
            case "signedOut": result["state"] = .string("notConfigured")
            default: break
            }
        }
        result["kind"] = .string(Self.serviceKind(service))
        return .object(result)
    }

    func loginService(domain: String, purpose: String) async throws -> JSONValue? {
        guard !domain.isEmpty else {
            throw RuntimeError.bridge("Access requests require a non-empty domain")
        }
        let service = try await resolveService(domain)
        guard service.supportsAuthentication else {
            throw RuntimeError.bridge("\(domain) declares no access handoff")
        }
        return try await tracked(Actions.serviceLogin, .object(["domain": .string(domain)]), purpose: purpose) {
            await service.checkAccess(policy: .current, reason: .modelLogin)
            if service.loginState.isAuthenticated {
                Log.session.info("bridge.service.login already authenticated domain=\(domain) auth=\(service.loginState.rawValue)")
                return service.accessResult()
            }
            let control = ServiceControl.login(domain: domain, serviceName: service.title)
            Log.session.info("bridge.service.login handoff domain=\(domain) auth=\(service.loginState.rawValue)")
            guard await presentControl(control, service) != nil else {
                throw OxFunctionError(code: "handoff_incomplete", message: "The user cancelled or access setup failed.", recovery: "Do not reopen login automatically. Ask the user whether to continue, then inspect the service's login state before trying again.")
            }
            try Task.checkCancellation()
            return service.accessResult()
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

    private static func manifestPath(_ service: Service) -> String {
        let kind = serviceKind(service)
        let repository: String
        if case .repository(let id, _) = service.definition.source { repository = id }
        else { repository = service.isIOSService ? Repository.bundledID : Repository.localID }
        let identity = service.domain.hasPrefix("ios:") ? String(service.domain.dropFirst(4)) : service.domain
        return "repositories/\(repository)/\(kind)/\(identity)/service.json"
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
        let login: Service.LoginState
        let saved: Bool
        let attached: Bool
        let matchedAction: MatchedAction?

        init(match: ServiceManager.ServiceMatch, attached: Bool, kind: String) {
            let snapshot = match.service.snapshot(attached: attached)
            domain = snapshot.domain
            self.kind = kind
            manifestPath = ServiceOperations.manifestPath(match.service)
            if case .repository(let id, let provenance) = match.service.definition.source {
                repository = id
                repositoryProvenance = provenance.rawValue
            } else {
                repository = nil
                repositoryProvenance = nil
            }
            name = snapshot.name
            description = snapshot.description
            login = snapshot.login
            saved = snapshot.saved
            self.attached = snapshot.attached
            matchedAction = match.matchedActionID.flatMap { id in
                match.matchedAction.map { MatchedAction(id: id, label: $0) }
            }
        }
    }
}

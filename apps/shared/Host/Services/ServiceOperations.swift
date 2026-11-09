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
    let readMCPFile: (String, String) async throws -> Data
    let receiveFiles: @MainActor ([RemoteMCPFile]) async throws -> Void
    let serviceChanged: (String) -> Void
    let begin: (String, JSONValue, String) -> UUID
    let finish: (UUID, Result<JSONValue?, Error>) -> Void
    let native: NativeServiceOperations
    let presentServiceHandoff: ((Service, Service.ServiceWebPage, ServiceHandoffSession) async -> ServiceHandoffSession.Outcome)?
    let rememberSecret: ((SecretEntrySpec) async -> Bool)?

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
        readMCPFile: @escaping (String, String) async throws -> Data = { _, _ in throw RuntimeError.bridge("This caller cannot transfer local MCP files") },
        receiveFiles: @escaping @MainActor ([RemoteMCPFile]) async throws -> Void,
        serviceChanged: @escaping (String) -> Void,
        begin: @escaping (String, JSONValue, String) -> UUID,
        finish: @escaping (UUID, Result<JSONValue?, Error>) -> Void,
        native: NativeServiceOperations,
        presentServiceHandoff: ((Service, Service.ServiceWebPage, ServiceHandoffSession) async -> ServiceHandoffSession.Outcome)? = nil,
        rememberSecret: ((SecretEntrySpec) async -> Bool)? = nil
    ) {
        self.serviceManager = serviceManager
        self.conversationOwner = conversationOwner
        self.resolveConversationAttachments = resolveConversationAttachments
        self.resolveService = resolveService
        self.resolveAction = resolveAction
        self.attachedDomains = attachedDomains
        self.requireApproval = approve
        self.presentControl = presentControl
        self.readMCPFile = readMCPFile
        self.receiveFiles = receiveFiles
        self.serviceChanged = serviceChanged
        self.begin = begin
        self.finish = finish
        self.native = native
        self.presentServiceHandoff = presentServiceHandoff
        self.rememberSecret = rememberSecret
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
        let hostStandard = !service.isWebService && service.definition.standardServiceActions.contains { $0.id == actionID }
        if service.isMCPService, !hostStandard, await service.loadManifest(reason: .invoke) == nil {
            throw RuntimeError.bridge("Service capabilities are unavailable; invoke the server's authorize action if authorization is required")
        }
        try service.definition.validateStandardServiceActions()
        var input = args ?? .object([:])
        if session != nil || pageURL != nil {
            guard service.isWebService, let baseURL = service.definition.baseURL else {
                throw RuntimeError.bridge("Session routing is supported only for web services")
            }
            _ = try service.executionURL(defaultURL: baseURL, session: session, pageURL: pageURL)
        }
        let qualifiedName = service.definition.qualifiedActionName(actionID)
        guard let action = service.definition.action(actionID), let inputSchema = service.definition.inputSchema(for: action) else {
            throw Service.InvokeError.unknown(qualifiedName)
        }
        if service.isWebService, actionID == "search", service.definition.standardServiceActions.contains(where: { $0.id == actionID }),
           let schema = ModelGuidance.standardServiceActions.objectValue?["web"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(actionID) })?.objectValue?["inputSchema"],
           let maximum = inputSchema.objectValue?["properties"]?.objectValue?["limit"]?.objectValue?["maximum"]?.intValue {
            let violations = JSONSchemaValidator.validate(input, against: schema, definitions: [:])
            guard violations.isEmpty else { throw Service.InvokeError.invalidInput(qualifiedName, violations) }
            var fields = input.objectValue ?? [:]
            fields["limit"] = .int(min(fields["limit"]?.intValue ?? 10, maximum))
            input = .object(fields)
        }
        let recordedInput: JSONValue = session == nil && pageURL == nil ? input : .object([
            "input": input,
            "session": session ?? .null,
            "pageUrl": pageURL.map(JSONValue.string) ?? .null,
        ])
        let prepared = try SecretAttempt.prepare(input)
        if !prepared.keys.isEmpty, hostStandard {
            throw RuntimeError.bridge("Secret references are not supported for this action")
        }
        input = prepared.args
        let inputViolations = JSONSchemaValidator.validate(
            input,
            against: inputSchema,
            definitions: service.definition.definitions,
            allowingSecretReferences: !prepared.keys.isEmpty
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
            if hostStandard {
                let value = try await self.invokeStandardServiceAction(service, actionID: actionID, purpose: purpose)
                let violations = JSONSchemaValidator.validate(value ?? .null, against: action.outputSchema ?? .null, definitions: [:])
                guard violations.isEmpty else { throw Service.InvokeError.invalidOutput(qualifiedName, violations) }
                return value
            }
            let secrets = prepared.keys.isEmpty ? nil : SecretAttempt(consumer: qualifiedName, keys: prepared.keys) { use, label in
                do {
                    try await self.requireApproval(
                        action: use.action,
                        defaultPolicy: .ask,
                        purpose: purpose,
                        prompt: L10n.string("Allow \(qualifiedName) to use the saved secret \(label)?\nOnly the service that owns it can read it, on its own domain. It never enters the conversation.")
                    )
                    return true
                } catch {
                    return false
                }
            }
            if let secrets, await !secrets.authorize() {
                throw OxFunctionError(code: "permission_denied", message: "\(qualifiedName): the user did not allow this action to use the saved secret.", recovery: "Stop. Do not retry with the same secret unless the user asks; offer manual login instead.")
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
            if let secrets, WebSessionContract.isEnabled(service.definition), actionID == WebSessionContract.loginAction,
               await self.hasIntendedSession(service: service, secrets: secrets, approve: approve) {
                Log.service.info("Service.login automatic skipped domain=\(service.domain) reason=signed-in")
                return .object(["interaction": .string("automatic"), "authentication": .string("verified")])
            }
            if service.definition.supportsConversation, actionID == WebConversationContract.actionID {
                let attachments = try await resolveConversationAttachments(input.objectValue?["attachments"]?.arrayValue ?? [])
                return try await serviceManager.invokeConversation(service: service, args: input, owner: conversationOwner, attachments: attachments, session: session, pageURL: pageURL, approve: approve)
            }
            let result: Result<JSONValue, Error>
            if let implementation = service.apiService {
                result = await implementation.invoke(service: service, actionID: actionID, args: input, secrets: secrets, approve: approve)
            } else if let implementation = service.iOSService {
                let dispatched = try await secrets?.substitute(input, caller: service.definition.actionNamespace) ?? input
                result = await implementation.invoke(
                    service: service, actionID: actionID, args: dispatched, purpose: purpose,
                    approve: approve,
                    nativeInvocation: { _, id, args, purpose in
                        try await self.native.invoke(service: service, actionID: id, args: args, purpose: purpose)
                    }
                )
            } else if let implementation = service.remoteMCPService {
                let dispatched = try await secrets?.substitute(input, caller: service.definition.actionNamespace) ?? input
                result = await implementation.invoke(
                    service: service, actionID: actionID, args: dispatched,
                    approve: approve, readFile: { try await self.readMCPFile($0, purpose) }, receiveFiles: receiveFiles
                )
            } else if let secrets, actionID == WebSessionContract.loginAction,
                      secrets.owners.contains(where: { $0 != service.definition.actionNamespace }) {
                result = .success(.null)
            } else {
                result = await service.invokeAction(
                    actionID,
                    args: input,
                    session: session,
                    pageURL: pageURL,
                    secrets: secrets,
                    approve: approve
                )
            }
            let raw: JSONValue
            do { raw = try result.get() } catch {
                if WebSessionContract.isEnabled(service.definition), actionID == WebSessionContract.loginAction,
                   secrets == nil, self.redirectProvider(for: service) != nil {
                    return try await self.completeLogin(service: service, secrets: nil, input: input, session: session,
                                                        pageURL: pageURL, approve: approve)
                }
                secrets?.releaseRendering()
                throw error
            }
            let value = secrets?.redact(raw) ?? raw
            if WebSessionContract.isEnabled(service.definition), actionID == WebSessionContract.loginAction {
                return try await self.completeLogin(service: service, secrets: secrets, input: input, session: session,
                                                    pageURL: pageURL, approve: approve)
            }
            secrets?.releaseRendering()
            return value
        }
    }

    func validateService(domain: String, purpose: String) async throws -> JSONValue? {
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await tracked(Actions.serviceValidate, .object(["domain": .string(domain)]), purpose: purpose) {
            try await self.serviceManager.validateService(domain: domain)
            return .object(["domain": .string(domain), "valid": .bool(true)])
        }
    }

    func createService(kind: String, domain: String, name: String, endpoint: String?, transport: String?, faviconURL: JSONValue?, purpose: String) async throws -> JSONValue? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == "mcp", domain.isEmpty, !name.isEmpty, let endpoint else {
            throw RuntimeError.bridge("ox.service.create: MCP requires a nonempty name, endpoint, and no domain. Create web/API source with ox.fs under repositories/local/.")
        }
        return try await saveMCP(endpoint: endpoint, transport: transport, faviconURL: faviconURL, replacing: nil, name: name, purpose: purpose)
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
        guard let connectionName = name ?? replacing?.definition.name else {
            throw RuntimeError.bridge("MCP requires a name.")
        }
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
                name: connectionName,
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

    func inspectService(domain: String, cursor: String?, purpose: String) async throws -> JSONValue? {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDomain.isEmpty, cleanDomain.count <= 500 else {
            throw RuntimeError.bridge("ox.service.inspect: domain must contain 1-500 characters")
        }
        let service = try await resolveService(cleanDomain)
        var fields: [String: JSONValue] = ["domain": .string(cleanDomain)]
        if let cursor { fields["cursor"] = .string(cursor) }
        return try await tracked(Actions.serviceInspect, .object(fields), purpose: purpose) {
            guard await service.loadManifest(reason: .inspect) != nil else {
                let reason: String
                if case .unavailable(let error) = service.capabilityState { reason = error }
                else { reason = "Service capabilities could not be loaded." }
                throw OxFunctionError(code: "capabilities_unavailable", message: reason, recovery: "Invoke the service's standard setup action if authorization is required; otherwise inspect the source or connection error. Failure does not establish that the service has no actions.")
            }
            let definition = service.definition
            try definition.validateStandardServiceActions()
            let standard = definition.standardServiceActions
            let ids = Set(standard.map(\.id))
            let actions = definition.exposedActions.filter { !ids.contains($0.id) }.sorted { $0.id < $1.id }
            let start: Int
            if let cursor {
                guard let previous = actions.firstIndex(where: { definition.qualifiedActionName($0.id) == cursor }) else {
                    throw OxFunctionError(code: "invalid_argument", message: "Invalid or stale service inspection cursor.", recovery: "Inspect the same service without cursor to restart pagination.")
                }
                start = previous + 1
            } else { start = 0 }
            let page = actions.dropFirst(start).prefix(10)
            let details = try Dictionary(uniqueKeysWithValues: page.map { action in
                guard let detail = OxActions.detail(definition: definition, id: action.id) else {
                    throw RuntimeError.bridge("ox.service.inspect: missing action contract '\(action.id)'.")
                }
                return (action.id, detail)
            })
            try Secret.inferMissingTypes()
            let secrets = try Secret.associatedEntries(namespace: definition.actionNamespace)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            var result: [String: JSONValue] = [
                "service": try self.serviceSnapshot(service),
                "standardActions": .array(standard.map { .string($0.id) }),
                "actions": .object(details),
                "secrets": .array(secrets.map { entry in
                    .object([
                        "key": .string(entry.key),
                        "displayName": .string(entry.displayName),
                        "type": .string(entry.type?.rawValue ?? ""),
                    ])
                }),
            ]
            if start + page.count < actions.count, let last = page.last {
                result["nextCursor"] = .string(definition.qualifiedActionName(last.id))
            }
            Log.session.info("bridge.service.inspect domain=\(cleanDomain) count=\(details.count) continued=\(cursor != nil) more=\(result["nextCursor"] != nil)")
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
                if let name = serviceManager.serviceNames[domain] { fields["name"] = .string(name) }
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

    func showServicePage(name: String, args: JSONValue?, session: JSONValue? = nil, pageURL: String? = nil, waitForUserInteraction: Bool = false, purpose: String) async throws -> JSONValue? {
        let (service, actionID) = try await resolveAction(name)
        let input = args ?? .object([:])
        guard service.isWebService,
              await service.resolvedAction(actionID, args: input, session: session, pageURL: pageURL) != nil else {
            throw RuntimeError.bridge("ox.service.showPage: requires a web service action")
        }
        return try await tracked(Actions.serviceShowPage, .object(["name": .string(name), "input": input, "session": session ?? .null, "pageUrl": pageURL.map(JSONValue.string) ?? .null, "waitForUserInteraction": .bool(waitForUserInteraction)]), purpose: purpose) {
            let page = service.servicePages.filter { page in
                guard let prepared = page.lastInvocation else { return false }
                return prepared.actionID == actionID && prepared.args == input
                    && prepared.requestedSession == session && prepared.pageURL == pageURL
            }.max { ($0.lastInvocation?.startedAt ?? .distantPast) < ($1.lastInvocation?.startedAt ?? .distantPast) }
            guard let page, let prepared = page.lastInvocation,
                  let action = await service.resolvedAction(actionID, args: input, session: prepared.selectedSession, pageURL: prepared.pageURL),
                  let lease = try await serviceManager.actionScheduler.reserveForPresentation(action, allowUnready: true) else {
                throw OxFunctionError(code: "page_unavailable", message: "ox.service.showPage: this action has no idle live page.", recovery: "Wait for active actions to finish. Use the name and input of the action whose page you want to show. This function never opens a replacement page or reruns the action.")
            }
            defer { lease.release() }
            guard lease.page === page, page.lastInvocation?.id == prepared.id else {
                throw OxFunctionError(code: "page_unavailable", message: "The prepared page changed before presentation.", recovery: "Inspect the current page state. Do not rediscover a different account or repeat a mutation to replace the page.")
            }
            try await self.requirePresentablePage(service: service, page: lease.page)
            guard lease.isActive, page.lastInvocation?.id == prepared.id else {
                throw Service.EvalError.contextInvalidated
            }
            if waitForUserInteraction {
                let handoff = ServiceHandoffSession(
                    service: service,
                    servicePage: lease.page,
                    title: service.title,
                    navigationTitle: service.title
                )
                let outcome: ServiceHandoffSession.Outcome
                if let presentServiceHandoff {
                    outcome = await presentServiceHandoff(service, lease.page, handoff)
                } else {
                    outcome = await native.presentations.serviceHandoff.present(session: handoff)
                }
                try Task.checkCancellation()
                guard outcome != .failed, lease.isActive else {
                    throw OxFunctionError(code: "page_unavailable", message: "The live page interaction could not be completed.", recovery: "Inspect the preserved page. Do not reopen automatically or repeat a mutation.")
                }
                Log.service.info("Service.showPage interaction domain=\(service.domain) action=\(actionID) session=\(lease.page.logLabel) outcome=\(outcome.rawValue)")
                return .object(["shown": .bool(true), "completion": .string(outcome.rawValue)])
            }
            try native.presentServicePage(service, page: lease.page)
            Log.service.info("Service.showPage shown domain=\(service.domain) action=\(actionID) session=\(lease.page.logLabel)")
            return .object(["shown": .bool(true)])
        }
    }

    func requirePresentablePage(service: Service, page: Service.ServiceWebPage) async throws {
        let generation = page.navigationGeneration
        guard service.owns(page),
              let scheme = page.page.url?.scheme?.lowercased(), ["http", "https"].contains(scheme),
              !page.page.isLoading, !page.page.isBlockedByScreenTime else {
            throw OxFunctionError(code: "page_unavailable", message: "The live page is unavailable, blocked, or still loading.", recovery: "Inspect the preserved page and verify the intended user step before requesting interaction. Do not repeat a mutation to prepare another page.")
        }
        let ready = try await service.evalAsync(page, """
        return document.readyState !== 'loading' && Boolean(document.body && (
          document.body.innerText.trim() ||
          Array.from(document.body.querySelectorAll('button,input:not([type="hidden"]),select,textarea,iframe,canvas,img,svg,video,object,embed'))
            .some(element => element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }))
        ));
        """, context: "handoff-preflight", timeout: 3)
        guard service.owns(page), page.navigationGeneration == generation,
              !page.page.isLoading, !page.page.isBlockedByScreenTime else {
            throw Service.EvalError.contextInvalidated
        }
        guard ready as? Bool == true else {
            throw OxFunctionError(code: "page_unavailable", message: "The live page has no loaded content for the user.", recovery: "Inspect and repair page preparation before requesting interaction. Do not repeat a mutation or treat an empty page as a login or verification step.")
        }
        Log.service.info("Service.handoff preflight domain=\(service.domain) page=\(page.logLabel) nav=\(generation) ready=true")
    }

    private func invokeStandardServiceAction(_ service: Service, actionID: String, purpose: String) async throws -> JSONValue? {
        if ["credentialStatus", "connectionStatus", "permissionStatus"].contains(actionID) {
            guard serviceManager.actionPolicy(for: Actions.serviceCheckAccess, default: .allow) == .allow else {
                throw OxFunctionError(code: "permission_denied", message: "Status inspection is blocked by the existing access-check policy.", recovery: "Stop. Do not bypass the policy through another action.")
            }
            let auth: Service.Auth
            if let api = service.apiService { auth = try api.authorization.configuredAccess() }
            else if let mcp = service.remoteMCPService { auth = try await mcp.checkAccess() }
            else { auth = try await service.readAccess() }
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
            return .object(["state": .string(state)])
        }
        try await requireApproval(action: Actions.serviceLogin, defaultPolicy: Actions.defaultPolicy(for: Actions.serviceLogin), args: ["domain": service.domain], purpose: purpose)
        if !service.supportsAuthentication {
            return .object(["completed": .bool(true), "completion": .string("notRequired"), "state": .string("notRequired")])
        }
        let result = try await requestServiceSetup(service)
        guard let observedState = result.objectValue?["state"]?.stringValue else {
            throw RuntimeError.bridge("Setup returned no state evidence")
        }
        let state: String
        if service.isAPIService {
            switch observedState {
            case "signedIn": state = "configured"
            case "signedOut": state = "notConfigured"
            default: state = observedState
            }
        } else { state = observedState }
        let completion = service.auth == .notRequired ? "notRequired" : service.isAPIService ? "configured" : "authorized"
        return .object(["completed": .bool(true), "completion": .string(completion), "state": .string(state)])
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
            try await self.requestServiceSetup(service)
        }
    }

    private func requestServiceSetup(_ service: Service) async throws -> JSONValue {
        await service.checkAccess(policy: .current, reason: .modelLogin)
        if service.auth == .notRequired || service.loginState.isAuthenticated {
            Log.session.info("bridge.service.login setup unnecessary domain=\(service.domain) auth=\(service.loginState.rawValue)")
            return service.accessResult()
        }
        let control = ServiceControl.login(domain: service.domain, serviceName: service.title)
        Log.session.info("bridge.service.login handoff domain=\(service.domain) auth=\(service.loginState.rawValue)")
        guard await presentControl(control, service) != nil else {
            throw OxFunctionError(code: "handoff_incomplete", message: "Login did not finish: the user tapped Cancel or closed the login page, or sign-in did not complete. \(service.title) is still not signed in.", recovery: "Tell the user login was not completed. Do not reopen login automatically; ask whether they want to try again, then inspect the service's login state before retrying.")
        }
        try Task.checkCancellation()
        return service.accessResult()
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

import Foundation

nonisolated enum ServiceIcon: Equatable, Sendable {
    case asset(String)
    case system(String)

    static let fallback = ServiceIcon.system("network")
}

nonisolated struct ServiceDefinition: Sendable {
    enum Source: Equatable, Sendable {
        case repository(id: String, provenance: Repository.Descriptor.Provenance)
        case iOS(icon: ServiceIcon?, permission: NativePermission?)
        case mcp(endpoint: URL, transport: RemoteMCPTransport?, icon: ServiceIcon)
    }

    enum ValidationError: LocalizedError {
        case missing(String)
        case invalid(String)
        case duplicateAction(String)

        var errorDescription: String? {
            switch self {
            case let .missing(field): "missing \(field)"
            case let .invalid(field): "invalid \(field)"
            case let .duplicateAction(id): "duplicate action \(id)"
            }
        }
    }

    let manifest: JSONValue
    let source: Source
    let repositoryID: String?
    let domain: String
    let name: String
    let description: String
    let baseURL: URL?
    let faviconURL: URL?
    let actions: [Manifest.Action]
    let actionIndex: [String: Manifest.Action]
    let definitions: [String: JSONValue]
    let remoteMCPIcons: [RemoteMCPIcon]

    init(
        manifest: JSONValue,
        repositoryID: String = Repository.bundledID,
        provenance: Repository.Descriptor.Provenance = .bundled
    ) throws {
        try ServiceSourceValidation.validateManifest(manifest)
        guard let object = manifest.objectValue else { throw ValidationError.invalid("root") }
        guard let domain = object["domain"]?.stringValue?.lowercased(), !domain.isEmpty else {
            throw ValidationError.missing("domain")
        }
        guard let name = object["name"]?.stringValue, !name.isEmpty else {
            throw ValidationError.missing("name")
        }
        let api = object["kind"]?.stringValue == "api"
        if api {
            guard let auth = object["auth"], domain.range(of: "^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$", options: .regularExpression) != nil else {
                throw ValidationError.invalid("API identity or authentication")
            }
            _ = try APIServiceAuth(auth)
        } else if object["kind"] != nil || object["auth"] != nil {
            throw ValidationError.invalid("kind or auth")
        }
        guard let rawBaseURL = object["baseUrl"]?.stringValue,
              let baseURL = URL(string: rawBaseURL),
              baseURL.scheme == "http" || baseURL.scheme == "https",
              let host = baseURL.host?.lowercased(),
              api ? APIServiceAuth.validEndpoint(baseURL) && WebFetchURLPolicy.allows(baseURL)
                  : Self.isServiceHost(host, domain: domain) else {
            throw ValidationError.invalid("baseUrl")
        }
        guard let faviconValue = object["faviconUrl"]?.stringValue else {
            throw ValidationError.missing("faviconUrl")
        }
        let faviconURL = try Self.faviconURL(faviconValue)
        let rawActions = object["actions"]?.arrayValue ?? []
        let actions = try rawActions.map { value in
            guard let action = Manifest.Action(value, serviceDomain: api ? nil : domain, serviceBaseURL: baseURL),
                  !action.id.isEmpty,
                  action.inputSchema != nil,
                  action.outputSchema != nil else {
                throw ValidationError.invalid("action")
            }
            return action
        }
        var actionIndex: [String: Manifest.Action] = [:]
        for action in actions {
            guard actionIndex[action.id] == nil else { throw ValidationError.duplicateAction(action.id) }
            if api {
                guard action.raw["baseUrl"] == nil, action.raw["blocking"] == nil,
                      action.raw["requireAuth"]?.boolValue != nil, action.raw["requireApproval"]?.boolValue != nil,
                      !["getSignInUrl", "getSignInState"].contains(action.id),
                      !action.requireAuth || object["auth"]?.objectValue?["type"]?.stringValue != "none" else {
                    throw ValidationError.invalid("API action")
                }
            }
            if !api, let host = action.baseURL?.host?.lowercased(), !Self.isServiceHost(host, domain: domain) {
                throw ValidationError.invalid("action baseUrl")
            }
            actionIndex[action.id] = action
        }
        guard object["skills"] == nil else { throw ValidationError.invalid("skills belong in the repository") }
        self.manifest = manifest
        self.source = .repository(id: repositoryID, provenance: provenance)
        self.repositoryID = repositoryID
        self.domain = domain
        self.name = name
        self.description = object["description"]?.stringValue ?? ""
        self.baseURL = baseURL
        self.faviconURL = faviconURL
        self.actions = actions
        self.actionIndex = actionIndex
        self.definitions = object["$defs"]?.objectValue ?? [:]
        self.remoteMCPIcons = []
        try validateStandardServiceActions()
    }

    init(iOS manifest: IOSCatalogManifest, repositoryID: String? = nil) throws {
        guard manifest.isValid else {
            throw ValidationError.invalid("iOS manifest")
        }
        let baseURL = manifest.domain == "ios:browser" ? URL(string: "about:blank")! : nil
        let resolvedActions = try manifest.actions.map { value in
            guard let action = Manifest.Action(value, serviceBaseURL: baseURL),
                  action.id.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
                  action.inputSchema != nil,
                  action.outputSchema != nil else {
                throw ValidationError.invalid("iOS action")
            }
            return action
        }
        var actionIndex: [String: Manifest.Action] = [:]
        for action in resolvedActions {
            guard actionIndex[action.id] == nil else { throw ValidationError.duplicateAction(action.id) }
            actionIndex[action.id] = action
        }
        self.manifest = manifest.jsonValue
        self.source = .iOS(icon: manifest.icon?.value, permission: manifest.permission)
        self.repositoryID = repositoryID
        self.domain = manifest.domain
        self.name = manifest.name
        self.description = manifest.description ?? ""
        self.baseURL = baseURL
        self.faviconURL = try Self.faviconURL(manifest.faviconUrl)
        self.actions = resolvedActions
        self.actionIndex = actionIndex
        self.definitions = [:]
        self.remoteMCPIcons = []
        try validateStandardServiceActions()
    }

    init(mcp manifest: MCPCatalogManifest, repositoryID: String? = nil) throws {
        self.init(
            mcpEndpoint: manifest.endpoint,
            domain: manifest.id,
            transport: manifest.transport,
            name: manifest.name,
            description: manifest.description,
            repositoryID: repositoryID,
            faviconURL: try Self.faviconURL(manifest.faviconUrl)
        )
    }

    init(
        mcpEndpoint endpoint: URL,
        domain: String,
        transport: RemoteMCPTransport?,
        name: String,
        description: String? = nil,
        repositoryID: String? = nil,
        faviconURL: URL? = nil
    ) {
        let resolvedDescription = description ?? "Remote MCP server at \(endpoint.host ?? endpoint.absoluteString)"
        self.manifest = .object([
            "domain": .string(domain),
            "name": .string(name),
            "description": .string(resolvedDescription),
            "baseUrl": .string(endpoint.absoluteString),
            "actions": .array([]),
        ])
        self.source = .mcp(endpoint: endpoint, transport: transport, icon: .fallback)
        self.repositoryID = repositoryID
        self.domain = domain
        self.name = name
        self.description = resolvedDescription
        self.baseURL = endpoint
        self.faviconURL = faviconURL
        self.actions = []
        self.actionIndex = [:]
        self.definitions = [:]
        self.remoteMCPIcons = []
    }

    init(mcp descriptor: RemoteMCPDescriptor, metadata: ServiceDefinition) {
        let actions = descriptor.tools.compactMap { tool in
            Manifest.Action(.object([
                "id": .string(tool.name),
                "label": .string(tool.title),
                "description": tool.description.map(JSONValue.string) ?? .null,
                "inputSchema": RemoteMCPAttachments.inputSchema(tool.inputSchema),
                "outputSchema": tool.outputSchema ?? .object([:]),
                "requireApproval": .bool(true),
                "requireAuth": .bool(false),
            ]))
        }
        let name = metadata.name
        let description = metadata.description
        self.manifest = .object([
            "domain": .string(metadata.domain),
            "name": .string(name),
            "description": .string(description),
            "baseUrl": .string(descriptor.endpoint.absoluteString),
            "actions": .array(actions.map { .object($0.raw) }),
        ])
        self.source = .mcp(endpoint: descriptor.endpoint, transport: descriptor.transport, icon: .fallback)
        self.repositoryID = metadata.repositoryID
        self.domain = metadata.domain
        self.name = name
        self.description = description
        self.baseURL = descriptor.endpoint
        self.faviconURL = metadata.faviconURL
        self.actions = actions
        self.actionIndex = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        self.definitions = [:]
        self.remoteMCPIcons = descriptor.icons
    }

    private static func isServiceHost(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    static func faviconURL(_ value: String?) throws -> URL? {
        guard let value else { return nil }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              WebFetchURLPolicy.allows(url) else {
            throw ValidationError.invalid("faviconUrl")
        }
        return url
    }

    var standardServiceActions: [Manifest.Action] {
        if !isAPI && !isIOS && !isMCP {
            return ModelGuidance.standardServiceActions.objectValue?["web"]?.arrayValue?.compactMap { value in
                guard let expected = value.objectValue, let id = expected["id"]?.stringValue,
                      let action = actionIndex[id] else { return nil }
                if [WebSessionContract.listAction, WebSessionContract.loginAction].contains(id) {
                    guard WebSessionContract.isEnabled(self) else { return nil }
                    guard id == WebSessionContract.loginAction else { return action }
                    var contract = action.raw
                    contract["description"] = expected["description"]
                    contract["outputSchema"] = expected["outputSchema"]
                    return Manifest.Action(.object(contract))
                }
                if id == "search" {
                    var contract = action.raw
                    for field in ["inputSchema", "outputSchema"] {
                        if var schema = contract[field]?.objectValue {
                            schema["$defs"] = .object(definitions)
                            contract[field] = .object(schema)
                        }
                    }
                    guard !action.requireApproval,
                          let input = try? OxSearch.searchInput(action: contract, service: domain),
                          let maximum = input.objectValue?["properties"]?.objectValue?["limit"]?.objectValue?["maximum"]?.intValue,
                          (1...50).contains(maximum) else { return nil }
                    return action
                }
                guard let input = action.inputSchema, let output = action.outputSchema,
                      (try? ModelServiceContract.normalized(input, definitions: definitions)) == (try? ModelServiceContract.normalized(expected["inputSchema"] ?? .null)),
                      (try? ModelServiceContract.normalized(output, definitions: definitions)) == (try? ModelServiceContract.normalized(expected["outputSchema"] ?? .null)) else { return nil }
                return action
            } ?? []
        }
        let kind = isAPI ? "api" : isIOS ? "ios" : "mcp"
        return ModelGuidance.standardServiceActions.objectValue?[kind]?.arrayValue?.compactMap { Manifest.Action($0) } ?? []
    }

    func validateStandardServiceActions() throws {
        guard isAPI || isIOS || isMCP else { return }
        let reserved = Set(standardServiceActions.map(\.id))
        if let collision = actions.first(where: { reserved.contains($0.id) }) {
            throw ValidationError.duplicateAction(collision.id)
        }
    }

    var exposedActions: [Manifest.Action] {
        let standard = standardServiceActions
        let ids = Set(standard.map(\.id))
        return standard + actions.filter { !isStandardAction($0.id) && !ids.contains($0.id) }
    }

    var isAPI: Bool { manifest.objectValue?["kind"]?.stringValue == "api" }

    var isIOS: Bool {
        if case .iOS = source { true } else { false }
    }

    var isMCP: Bool {
        if case .mcp = source { true } else { false }
    }

    var actionNamespace: String {
        switch source {
        case .repository: "\(isAPI ? "api" : "web"):\(domain)"
        case .iOS: domain
        case .mcp: "mcp:\(domain)"
        }
    }

    func qualifiedActionName(_ actionID: String) -> String {
        "\(actionNamespace):\(actionID)"
    }

    var icon: ServiceIcon? {
        switch source {
        case .repository: nil
        case .iOS(let icon, _): icon
        case .mcp(_, _, let icon): icon
        }
    }

    var iOSPermission: NativePermission? {
        if case .iOS(_, let permission) = source { permission } else { nil }
    }

    var mcpEndpoint: URL? {
        if case .mcp(let endpoint, _, _) = source { endpoint } else { nil }
    }

    var mcpTransport: RemoteMCPTransport? {
        if case .mcp(_, let transport, _) = source { transport } else { nil }
    }

    func action(_ id: String, includingStandard: Bool = false) -> Manifest.Action? {
        if isAPI || isIOS || isMCP, let action = standardServiceActions.first(where: { $0.id == id }) { return action }
        guard let action = actionIndex[id] else { return nil }
        return includingStandard || !isStandardAction(id) ? action : nil
    }

    var supportsConversation: Bool {
        !isAPI && !isIOS && !isMCP && actionIndex[WebConversationContract.actionID] != nil
    }

    func isStandardAction(_ id: String) -> Bool {
        !isAPI && !isIOS && !isMCP && ModelServiceContract.generationIDs.contains(id)
    }
}

nonisolated enum Manifest {
    nonisolated struct Action: Identifiable, Sendable {
        let id: String
        let label: String
        let description: String?
        let baseURL: URL?
        let blocking: Bool
        let inputSchema: JSONValue?
        let outputSchema: JSONValue?
        let requireApproval: Bool
        let requireAuth: Bool
        let raw: [String: JSONValue]

        init?(
            _ value: JSONValue,
            serviceDomain: String? = nil,
            serviceBaseURL: URL? = nil
        ) {
            guard let raw = value.objectValue, let id = raw["id"]?.stringValue else { return nil }
            self.id = id
            self.label = raw["label"]?.stringValue ?? id
            self.description = raw["description"]?.stringValue
            let inputSchema = raw["inputSchema"]
            if let rawBaseURL = raw["baseUrl"] {
                guard let value = rawBaseURL.stringValue,
                      let components = URLComponents(string: value),
                      Self.isValidBaseURLTemplate(components, inputSchema: inputSchema),
                      let baseURL = components.url,
                      baseURL.scheme == "http" || baseURL.scheme == "https",
                      baseURL.host != nil else { return nil }
                self.baseURL = baseURL
            } else {
                self.baseURL = serviceBaseURL
            }
            if let serviceDomain,
               let host = self.baseURL?.host?.lowercased(),
               host != serviceDomain,
               !host.hasSuffix("." + serviceDomain) { return nil }
            self.blocking = raw["blocking"]?.boolValue ?? false
            self.inputSchema = inputSchema
            self.outputSchema = raw["outputSchema"]
            self.requireApproval = raw["requireApproval"]?.boolValue == true
            self.requireAuth = raw["requireAuth"]?.boolValue == true
            self.raw = raw
        }

        func resolvedBaseURL(for args: JSONValue) -> URL? {
            guard let baseURL else { return nil }
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                return baseURL
            }
            let input = args.objectValue ?? [:]
            components.queryItems = components.queryItems?.compactMap { item in
                guard let inputName = Self.inputName(from: item.value) else { return item }
                guard let value = input[inputName]?.stringValue else { return nil }
                return URLQueryItem(name: item.name, value: value)
            }
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return components.url
        }

        private static func inputName(from value: String?) -> String? {
            guard let value, value.first == "{", value.last == "}", value.count > 2 else { return nil }
            let name = String(value.dropFirst().dropLast())
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { return nil }
            return name
        }

        private static func isValidBaseURLTemplate(_ components: URLComponents, inputSchema: JSONValue?) -> Bool {
            let fixedParts = [
                components.scheme,
                components.user,
                components.password,
                components.host,
                components.path,
                components.fragment,
            ].compactMap { $0 }
            guard fixedParts.allSatisfy({ !$0.contains("{") && !$0.contains("}") }) else { return false }
            let properties = inputSchema?.objectValue?["properties"]?.objectValue ?? [:]
            for item in components.queryItems ?? [] {
                guard !item.name.contains("{") && !item.name.contains("}") else { return false }
                let hasBraces = item.value?.contains("{") == true || item.value?.contains("}") == true
                guard hasBraces else { continue }
                guard let inputName = inputName(from: item.value),
                      properties[inputName]?.objectValue?["type"]?.stringValue == "string" else { return false }
            }
            return true
        }
    }

    // Overlay the locale's strings (name/description/action label+description) onto
    // the base manifest and drop the `locales` blob. The published manifest ships
    // every overlay so the device localizes offline; the locale comes from AppLocale.
    static func localized(_ manifest: JSONValue, locale: String?) -> JSONValue {
        guard var obj = manifest.objectValue else { return manifest }
        let overlay = locale.flatMap { obj["locales"]?.objectValue?[$0]?.objectValue }
        obj["locales"] = nil
        guard let overlay else { return .object(obj) }
        if let name = overlay["name"]?.stringValue { obj["name"] = .string(name) }
        if let desc = overlay["description"]?.stringValue { obj["description"] = .string(desc) }
        if let actionOverlays = overlay["actions"]?.objectValue, let actions = obj["actions"]?.arrayValue {
            obj["actions"] = .array(actions.map { a in
                guard var ao = a.objectValue, let id = ao["id"]?.stringValue,
                      let entry = actionOverlays[id]?.objectValue else { return a }
                if let label = entry["label"]?.stringValue { ao["label"] = .string(label) }
                if let desc = entry["description"]?.stringValue { ao["description"] = .string(desc) }
                return .object(ao)
            })
        }
        return .object(obj)
    }


}

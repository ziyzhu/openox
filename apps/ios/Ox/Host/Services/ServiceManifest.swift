import Foundation

nonisolated enum GetSignInStateOutcome: Equatable {
    case signedIn
    case signedOut
    case error(String)

    var logLabel: String {
        switch self {
        case .signedIn: "signedIn"
        case .signedOut: "signedOut"
        case .error: "error"
        }
    }
}

nonisolated struct GetSignInStateResult: Equatable {
    let outcome: GetSignInStateOutcome
    let at: Date

    init(_ outcome: GetSignInStateOutcome, at: Date = Date()) {
        self.outcome = outcome
        self.at = at
    }
}

nonisolated enum ServiceIcon: Equatable, Sendable {
    case asset(String)
    case system(String)
}

nonisolated struct ServiceDefinition: Sendable {
    enum Source: Equatable, Sendable {
        case repository(id: String, provenance: ServiceRepository.Repository.Provenance)
        case iOS(icon: ServiceIcon, permission: NativePermission?)
        case mcp(endpoint: URL, transport: RemoteMCPTransport?, icon: ServiceIcon)
    }

    enum ValidationError: LocalizedError {
        case missing(String)
        case invalid(String)
        case duplicateAction(String)
        case duplicateSkill(String)

        var errorDescription: String? {
            switch self {
            case let .missing(field): "missing \(field)"
            case let .invalid(field): "invalid \(field)"
            case let .duplicateAction(id): "duplicate action \(id)"
            case let .duplicateSkill(name): "duplicate skill \(name)"
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
    let skills: [Manifest.Skill]
    let remoteMCPIcons: [RemoteMCPIcon]

    init(
        manifest: JSONValue,
        repositoryID: String = ServiceRepository.bundledID,
        provenance: ServiceRepository.Repository.Provenance = .bundled
    ) throws {
        guard let object = manifest.objectValue else { throw ValidationError.invalid("root") }
        guard let domain = object["domain"]?.stringValue?.lowercased(), !domain.isEmpty else {
            throw ValidationError.missing("domain")
        }
        guard let name = object["name"]?.stringValue, !name.isEmpty else {
            throw ValidationError.missing("name")
        }
        guard let rawBaseURL = object["baseUrl"]?.stringValue,
              let baseURL = URL(string: rawBaseURL),
              baseURL.scheme == "http" || baseURL.scheme == "https",
              let host = baseURL.host?.lowercased(),
              Self.isServiceHost(host, domain: domain) else {
            throw ValidationError.invalid("baseUrl")
        }
        let faviconURL: URL?
        if let rawFaviconURL = object["faviconUrl"]?.stringValue {
            guard let parsed = URL(string: rawFaviconURL),
                  parsed.scheme?.lowercased() == "https",
                  WebFetchURLPolicy.allows(parsed) else {
                throw ValidationError.invalid("faviconUrl")
            }
            faviconURL = parsed
        } else {
            faviconURL = nil
        }
        let rawActions = object["actions"]?.arrayValue ?? []
        let actions = try rawActions.map { value in
            guard let action = Manifest.Action(value, serviceDomain: domain, serviceBaseURL: baseURL),
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
            if let host = action.baseURL?.host?.lowercased(), !Self.isServiceHost(host, domain: domain) {
                throw ValidationError.invalid("action baseUrl")
            }
            actionIndex[action.id] = action
        }
        let rawSkills = object["skills"]?.arrayValue ?? []
        let skills = try rawSkills.map { value in
            guard let skill = Manifest.Skill(value),
                  skill.name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
                throw ValidationError.invalid("skill")
            }
            return skill
        }
        var skillNames = Set<String>()
        for skill in skills {
            guard skillNames.insert(skill.name).inserted else { throw ValidationError.duplicateSkill(skill.name) }
        }
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
        self.skills = skills
        self.remoteMCPIcons = []
    }

    init(iOS manifest: IOSCatalogManifest, repositoryID: String? = nil) throws {
        guard manifest.isValid, let icon = manifest.icon.value else {
            throw ValidationError.invalid("iOS manifest")
        }
        let baseURL = manifest.domain == "ios:browser" ? URL(string: "https://www.google.com/")! : nil
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
        self.source = .iOS(icon: icon, permission: manifest.permission)
        self.repositoryID = repositoryID
        self.domain = manifest.domain
        self.name = manifest.name
        self.description = manifest.description ?? ""
        self.baseURL = baseURL
        self.faviconURL = nil
        self.actions = resolvedActions
        self.actionIndex = actionIndex
        self.definitions = [:]
        self.skills = []
        self.remoteMCPIcons = []
    }

    init(mcp manifest: MCPCatalogManifest, repositoryID: String? = nil) {
        self.init(
            mcpEndpoint: manifest.endpoint,
            transport: manifest.transport,
            name: manifest.name,
            description: manifest.description,
            repositoryID: repositoryID
        )
    }

    init(
        mcpEndpoint endpoint: URL,
        transport: RemoteMCPTransport?,
        name: String? = nil,
        description: String? = nil,
        repositoryID: String? = nil
    ) {
        let domain = RemoteMCPDescriptor.serviceID(for: endpoint)
        let resolvedName = name ?? endpoint.host ?? "Remote MCP"
        let resolvedDescription = description ?? "Remote MCP server at \(endpoint.host ?? endpoint.absoluteString)"
        self.manifest = .object([
            "domain": .string(domain),
            "name": .string(resolvedName),
            "description": .string(resolvedDescription),
            "baseUrl": .string(endpoint.absoluteString),
            "actions": .array([]),
        ])
        self.source = .mcp(endpoint: endpoint, transport: transport, icon: .asset("MCPFallback"))
        self.repositoryID = repositoryID
        self.domain = domain
        self.name = resolvedName
        self.description = resolvedDescription
        self.baseURL = endpoint
        self.faviconURL = nil
        self.actions = []
        self.actionIndex = [:]
        self.definitions = [:]
        self.skills = []
        self.remoteMCPIcons = []
    }

    init(mcp descriptor: RemoteMCPDescriptor, metadata: ServiceDefinition? = nil) {
        let actions = descriptor.tools.compactMap { tool in
            Manifest.Action(.object([
                "id": .string(tool.name),
                "label": .string(tool.title),
                "description": tool.description.map(JSONValue.string) ?? .null,
                "inputSchema": tool.inputSchema,
                "outputSchema": tool.outputSchema ?? .object([:]),
                "requireApproval": .bool(true),
                "requireAuth": .bool(false),
            ]))
        }
        let name = metadata?.name ?? descriptor.name
        let description = metadata?.description ?? descriptor.instructions
            ?? "Remote MCP server at \(descriptor.endpoint.host ?? descriptor.endpoint.absoluteString)"
        self.manifest = .object([
            "domain": .string(descriptor.id),
            "name": .string(name),
            "description": .string(description),
            "baseUrl": .string(descriptor.endpoint.absoluteString),
            "actions": .array(actions.map { .object($0.raw) }),
        ])
        self.source = .mcp(endpoint: descriptor.endpoint, transport: descriptor.transport, icon: .asset("MCPFallback"))
        self.repositoryID = metadata?.repositoryID
        self.domain = descriptor.id
        self.name = name
        self.description = description
        self.baseURL = descriptor.endpoint
        self.faviconURL = nil
        self.actions = actions
        self.actionIndex = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        self.definitions = [:]
        self.skills = []
        self.remoteMCPIcons = descriptor.icons
    }

    private static func isServiceHost(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    var exposedActions: [Manifest.Action] {
        actions.filter { !Manifest.STANDARD_ACTION_IDS.contains($0.id) }
    }

    var isIOS: Bool {
        if case .iOS = source { true } else { false }
    }

    var isMCP: Bool {
        if case .mcp = source { true } else { false }
    }

    var actionNamespace: String {
        switch source {
        case .repository: "web:\(domain)"
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
        case .iOS(let icon, _), .mcp(_, _, let icon): icon
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

    var supportsBotControl: Bool {
        actionIndex[Manifest.BOT_CONTROL_URL_ACTION_ID] != nil
            && actionIndex[Manifest.BOT_CONTROL_STATE_ACTION_ID] != nil
    }

    func action(_ id: String, includingStandard: Bool = false) -> Manifest.Action? {
        guard let action = actionIndex[id] else { return nil }
        return includingStandard || !Manifest.STANDARD_ACTION_IDS.contains(id) ? action : nil
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

    nonisolated struct Skill: Encodable, Sendable {
        let name: String
        let description: String

        init?(_ value: JSONValue) {
            guard let name = value.objectValue?["name"]?.stringValue,
                  let description = value.objectValue?["description"]?.stringValue else { return nil }
            self.name = name
            self.description = description
        }
    }

    static let SIGN_IN_URL_ACTION_ID = "getSignInUrl"
    static let SIGN_IN_STATE_ACTION_ID = "getSignInState"
    static let BOT_CONTROL_URL_ACTION_ID = "getBotControlUrl"
    static let BOT_CONTROL_STATE_ACTION_ID = "getBotControlState"
    static let PAYMENT_URL_ACTION_ID = "getPaymentUrl"
    static let PAYMENT_STATE_ACTION_ID = "getPaymentState"
    static let STANDARD_ACTION_IDS: Set<String> = [
        SIGN_IN_URL_ACTION_ID, SIGN_IN_STATE_ACTION_ID,
        BOT_CONTROL_URL_ACTION_ID, BOT_CONTROL_STATE_ACTION_ID,
        PAYMENT_URL_ACTION_ID, PAYMENT_STATE_ACTION_ID,
    ]

    static func authURL(_ v: JSONValue?) -> String? {
        v?.objectValue?["url"]?.stringValue
    }

    static func getSignInStateOutcome(_ v: JSONValue?) -> GetSignInStateOutcome {
        guard let signedIn = v?.objectValue?["signedIn"]?.boolValue else {
            return .error("getSignInState returned invalid output")
        }
        return signedIn ? .signedIn : .signedOut
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

    @MainActor
    static func getSignInState(service: Service) async -> GetSignInStateResult {
        for attempt in 1...2 {
            let result = await service.invokeAction(
                SIGN_IN_STATE_ACTION_ID,
                args: .object([:]),
                role: .authenticationProbe
            )
            switch result {
            case .success(let value):
                return GetSignInStateResult(getSignInStateOutcome(value))
            case .failure(let error):
                let contextInvalidated = if let evalError = error as? Service.EvalError,
                                           case .contextInvalidated = evalError {
                    true
                } else {
                    false
                }
                let invalidContract = if let invokeError = error as? Service.InvokeError,
                                         case .invalidContract = invokeError {
                    true
                } else {
                    false
                }
                let manifestRefreshing = service.resolutionState.resolved == nil
                guard attempt == 1,
                      !Task.isCancelled,
                      manifestRefreshing || contextInvalidated || invalidContract else {
                    return GetSignInStateResult(.error("getSignInState invoke failed"))
                }
                Log.service.info("Service.getSignInState retry domain=\(service.domain) attempt=\(attempt) manifestRefreshing=\(manifestRefreshing) contextInvalidated=\(contextInvalidated) invalidContract=\(invalidContract)")
                _ = await service.loadManifest(reason: .invoke)
            }
        }
        return GetSignInStateResult(.error("getSignInState invoke failed"))
    }
}

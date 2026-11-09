import Foundation

nonisolated enum WebSessionContract {
    static let listAction = "listSessions"
    static let loginAction = "login"

    static func isEnabled(_ definition: ServiceDefinition) -> Bool {
        !definition.isAPI && !definition.isIOS && !definition.isMCP
            && definition.actionIndex[listAction] != nil
            && definition.actionIndex[loginAction] != nil
    }

    static let sessionSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "id": .object(["type": .string("string"), "minLength": .int(1)]),
            "label": .object(["type": .string("string"), "minLength": .int(1)]),
            "url": .object(["type": .string("string"), "minLength": .int(1)]),
        ]),
        "required": .array(["id", "label", "url"].map(JSONValue.string)),
        "additionalProperties": .bool(false),
    ])

    static func destination(_ value: JSONValue, domain: String) throws -> URL {
        let violations = JSONSchemaValidator.validate(value, against: sessionSchema, definitions: [:])
        guard violations.isEmpty,
              let text = value.objectValue?["url"]?.stringValue else {
            throw RuntimeError.bridge("Invalid session descriptor; copy a session returned by listSessions")
        }
        return try destination(text, domain: domain)
    }

    static func destination(_ text: String, domain: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              host == domain || host.hasSuffix("." + domain),
              WebFetchURLPolicy.allows(url) else {
            throw RuntimeError.bridge("Execution URL must be a public HTTPS destination within the service domain")
        }
        return url
    }

    static func validateSessions(_ value: JSONValue, domain: String) throws {
        guard let sessions = value.arrayValue else {
            throw RuntimeError.bridge("listSessions must return an array")
        }
        var ids = Set<String>()
        for session in sessions {
            _ = try destination(session, domain: domain)
            guard let id = session.objectValue?["id"]?.stringValue,
                  ids.insert(id).inserted else {
                throw RuntimeError.bridge("listSessions returned duplicate session identifiers")
            }
        }
    }
}

extension Service {
    func invocationSession(
        action: Manifest.Action,
        session: JSONValue?,
        pageURL: String?,
        approve: (@MainActor (String, Any?) async -> Bool)?
    ) async throws -> JSONValue? {
        guard WebSessionContract.isEnabled(definition),
              action.id != WebSessionContract.listAction,
              action.id != WebSessionContract.loginAction else { return session }
        var selected = session
        if selected == nil {
            let discovered = try await invokeAction(WebSessionContract.listAction, args: .object([:]), pageURL: pageURL, approve: approve).get()
            selected = discovered.arrayValue?.first
            Log.service.info("Service.session default domain=\(domain) action=\(action.id) available=\(discovered.arrayValue?.count ?? 0) selected=\(selected != nil)")
        }
        guard !action.requireAuth || selected != nil else {
            throw OxFunctionError(code: "authentication_required", message: "No logged-in session was selected or discovered. No action was executed.", recovery: "Invoke the website's standard login action if needed, or listSessions to inspect available accounts. pageUrl does not select an authenticated session. Never fabricate a descriptor or automatically replay writes.")
        }
        return selected
    }

    func executionURL(defaultURL: URL, session: JSONValue?, pageURL: String?) throws -> URL {
        guard session != nil || pageURL != nil else { return defaultURL }
        guard WebSessionContract.isEnabled(definition) else {
            throw RuntimeError.bridge("Session routing requires listSessions/login")
        }
        if let session { _ = try WebSessionContract.destination(session, domain: domain) }
        if let pageURL { return try WebSessionContract.destination(pageURL, domain: domain) }
        return defaultURL
    }
}

import Foundation
import JavaScriptCore

nonisolated private func attachDefs(_ schema: JSONValue, defs: JSONValue?) -> JSONValue {
    guard case .object(var obj) = schema, let defs, case .object = defs else { return schema }
    if obj["$defs"] == nil { obj["$defs"] = defs }
    return .object(obj)
}

nonisolated enum OxActions {
    static let function = OxFunction(
        namespace: "service",
        schema: {
            [(
                "ox.service.invoke",
                .object([
                    "description": .string(ModelGuidance.text("ox.service.invoke")),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Backend-qualified service action name."),
                            ]),
                            "input": .object([
                                "type": .string("object"),
                                "description": .string("Input matching the action's inputSchema returned by `ox.service.inspect`."),
                            ]),
                            "session": WebSessionContract.sessionSchema,
                            "pageUrl": .object([
                                "type": .string("string"),
                                "description": .string("Initial target URL within the service domain, independent of the selected session/account context."),
                            ]),
                            "purpose": .object([
                                "type": .string("string"),
                                "minLength": .int(1),
                                "description": .string("Short (<10 words) description of why you're making this call, shown to the user as the step label."),
                            ]),
                        ]),
                        "required": .array([.string("name"), .string("purpose")]),
                        "additionalProperties": .bool(false),
                    ]),
                    "outputSchema": .object([
                        "description": .string("The action's output, which varies by the schema returned by `ox.service.inspect`."),
                    ]),
                ])
            )]
        },
        installNatives: { ctx, env in
            let invokeBlock: @convention(block) (String, JSValue, JSValue, JSValue, JSValue) -> JSValue = { name, argsValue, sessionValue, pageURLValue, purposeValue in
                let args = jsValueToJSON(argsValue)
                let purpose = purposeValue.toString()!
                let session = sessionValue.isNull || sessionValue.isUndefined ? nil : jsValueToJSON(sessionValue)
                let pageURL = pageURLValue.isNull || pageURLValue.isUndefined ? nil : pageURLValue.toString()
                return env.call(suspendingTimeout: true) { try await $0.invokeAction(name: name, args: args, session: session, pageURL: pageURL, purpose: purpose) }
            }
            ctx.setObject(invokeBlock as AnyObject, forKeyedSubscript: "__nativeAction" as NSString)
        },
        jsFragment: """
          invoke: (value) => { const options = __oxOptions(value, 'ox.service.invoke'); return __nativeAction(String(options.name), options.input ?? {}, options.session ?? null, options.pageUrl ?? null, String(options.purpose)); }
        """
    )

    static func index(definition: ServiceDefinition) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for action in definition.exposedActions {
            out[definition.qualifiedActionName(action.id)] = .object(metaFields(action.raw))
        }
        return out
    }

    static func detail(definition: ServiceDefinition, id: String) -> JSONValue? {
        guard let action = definition.action(id) else { return nil }
        let definitions = JSONValue.object(definition.definitions)
        var entry = metaFields(action.raw)
        entry["inputSchema"] = attachDefs(action.inputSchema ?? .object([:]), defs: definitions)
        entry["outputSchema"] = attachDefs(action.outputSchema ?? .null, defs: definitions)
        return .object(entry)
    }

    static func checkAccessOutput(kind: String) -> JSONValue {
        let evidence: String
        switch kind {
        case "web": evidence = "listSessions"
        case "api": evidence = "credentialConfiguration"
        case "mcp": evidence = "mcpConnection"
        default: evidence = "devicePermission"
        }
        var properties: [String: JSONValue] = [
            "domain": .object(["type": .string("string")]),
            "kind": .object(["const": .string(kind)]),
            "evidence": .object(["const": .string(evidence)]),
        ]
        if kind == "web" {
            properties["sessions"] = .object(["type": .string("array"), "items": WebSessionContract.sessionSchema])
        } else {
            let states: [String]
            switch kind {
            case "api": states = ["configured", "notConfigured", "notRequired"]
            case "mcp": states = ["authorized", "authorizationRequired", "notRequired"]
            default: states = ["authorized", "authorizationRequired", "denied", "notRequired"]
            }
            properties["state"] = .object(["type": .string("string"), "enum": .array(states.map(JSONValue.string))])
        }
        return .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(["domain", "kind", "evidence", kind == "web" ? "sessions" : "state"].map(JSONValue.string)), "additionalProperties": .bool(false),
        ])
    }

    static func requestAccessOutput(kind: String) -> JSONValue {
        var properties: [String: JSONValue] = [
            "domain": .object(["type": .string("string")]),
            "kind": .object(["const": .string(kind)]),
            "completed": .object(["type": .string("boolean"), "const": .bool(true)]),
            "completion": .object(["type": .string("string"), "enum": .array((kind == "web" ? ["acknowledged"] : ["verified", "configured", "authorized"]).map(JSONValue.string))]),
        ]
        if kind != "web" { properties["state"] = .object(["type": .string("string")]) }
        return .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array((["domain", "kind", "completed", "completion"] + (kind == "web" ? [] : ["state"])).map(JSONValue.string)), "additionalProperties": .bool(false),
        ])
    }

    @MainActor
    static func accessDetail(service: Service) -> JSONValue {
        let kind = ServiceOperations.serviceKind(service)
        let web = service.isWebService && WebSessionContract.isEnabled(service.definition)
        let supported = web || service.isMCPService || service.apiService?.authorization.auth.requiresCredentials == true || service.iOSService?.requiresPermission == true
        var access: [String: JSONValue] = ["kind": .string(kind)]
        guard supported else { return .object(access) }
        var properties: [String: JSONValue] = [
            "domain": .object(["type": .string("string"), "const": .string(service.domain)]),
            "purpose": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(80)]),
        ]
        if web { properties["pageUrl"] = .object(["type": .string("string")]) }
        access["checkAccess"] = .object([
            "function": .string("ox.service.checkAccess"),
            "description": .string("Read typed evidence without prompting; errors are not absence. API configuration is not server acceptance; MCP connectivity is not tool authorization. Website discovery respects Action policies. Invocations without session default to the first freshly discovered session, including when pageUrl is provided. Explicit selections are revalidated without switching accounts."),
            "inputSchema": .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(["purpose", "domain"].map(JSONValue.string)), "additionalProperties": .bool(false),
            ]),
            "outputSchema": checkAccessOutput(kind: kind),
        ])
        var required = ["purpose", "domain"]
        if web, let schema = service.definition.action(WebSessionContract.loginAction)?.inputSchema {
            properties["input"] = attachDefs(schema, defs: .object(service.definition.definitions))
            if !JSONSchemaValidator.validate(.object([:]), against: schema, definitions: service.definition.definitions).isEmpty {
                required.append("input")
            }
        }
        access["requestAccess"] = .object([
            "function": .string("ox.service.requestAccess"),
            "description": .string("Request user setup or interaction. Website completion is acknowledgment only: discover sessions afterward. API setup is configuration, not server acceptance. Never reopen cancellation or automatically replay writes."),
            "inputSchema": .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false),
            ]),
            "outputSchema": requestAccessOutput(kind: kind),
        ])
        return .object(access)
    }

    private static func metaFields(_ action: [String: JSONValue]) -> [String: JSONValue] {
        var entry: [String: JSONValue] = [:]
        if let label = action["label"]?.stringValue { entry["description"] = .string(label) }
        if let desc = action["description"]?.stringValue { entry["description"] = .string(desc) }
        entry["requireAuth"] = .bool(action["requireAuth"]?.boolValue ?? false)
        if let req = action["requireApproval"]?.boolValue, req { entry["requireApproval"] = .bool(true) }
        return entry
    }
}

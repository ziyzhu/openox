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
                                "description": .string("Initial target URL for session discovery, login, or public actions; cannot be combined with session."),
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

    static var loginDetail: JSONValue {
        .object([
            "function": .string("ox.service.login"),
            "description": .string("Call `await ox.service.login({ purpose, domain })` to ask the user to log in or authorize access. No service-specific input is required."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            "outputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "domain": .object(["type": .string("string")]),
                    "signedIn": .object(["type": .string("boolean")]),
                    "completed": .object(["type": .string("boolean"), "const": .bool(true)]),
                    "state": .object(["type": .string("string")]),
                    "completion": .object(["type": .string("string"), "enum": .array(["verified", "configured", "authorized", "acknowledged"].map(JSONValue.string))]),
                ]),
                "required": .array(["domain", "completed", "signedIn", "state", "completion"].map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ]),
        ])
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

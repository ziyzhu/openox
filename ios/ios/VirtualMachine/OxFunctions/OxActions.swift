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
                    "description": .string("Invoke a service action: `await ox.service.invoke({ name, input?, purpose })`, where `name` is `web:<domain>:<action>`, `ios:<app>:<action>`, or `mcp:<server>:<action>`. Discover actions and inspect their full input/output schemas with `ox.service.inspect` before invoking them. Throws if `requireApproval` is denied, or if `requireAuth` and the user is not signed in; surface that error instead of retrying blindly."),
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
            let invokeBlock: @convention(block) (String, JSValue, JSValue) -> JSValue = { name, argsValue, purposeValue in
                let args = jsValueToJSON(argsValue)
                let purpose = purposeValue.toString()!
                return env.call(suspendingTimeout: true) { try await $0.invokeAction(name: name, args: args, purpose: purpose) }
            }
            ctx.setObject(invokeBlock as AnyObject, forKeyedSubscript: "__nativeAction" as NSString)
        },
        jsFragment: """
          invoke: (value) => { const options = __oxOptions(value, 'ox.service.invoke'); return __nativeAction(String(options.name), options.input ?? {}, String(options.purpose)); }
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

    static func paymentDetail(definition: ServiceDefinition) -> JSONValue? {
        guard let url = definition.action(Manifest.PAYMENT_URL_ACTION_ID, includingStandard: true),
              let state = definition.action(Manifest.PAYMENT_STATE_ACTION_ID, includingStandard: true) else { return nil }
        let definitions = JSONValue.object(definition.definitions)
        return .object([
            "description": .string("Hands the prepared payment to the user for final review and commitment."),
            "inputSchema": attachDefs(url.inputSchema ?? .object([:]), defs: definitions),
            "outputSchema": attachDefs(state.outputSchema ?? .null, defs: definitions),
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

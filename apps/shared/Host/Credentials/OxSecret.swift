import Foundation
import JavaScriptCore

nonisolated enum OxSecret {
    static let function = OxFunction(
        namespace: "secret",
        schema: {
            [
                ("ox.secret.list", .object([
                    "description": .string(ModelGuidance.text("ox.secret.list")),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
                    "outputSchema": .object(["type": .string("array"), "items": .object([
                        "type": .string("object"), "properties": .object([
                            "key": .object(["type": .string("string")]), "displayName": .object(["type": .string("string")]),
                            "fields": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Sorted top-level field names only; empty when unavailable. Never secret values.")]),
                            "available": .object(["type": .string("boolean")]),
                        ]), "required": .array(["key", "displayName", "fields", "available"].map(JSONValue.string)), "additionalProperties": .bool(false),
                    ])]),
                ])),
                ("ox.secret.add", .object([
                    "description": .string(ModelGuidance.text("ox.secret.add")),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([
                        "key": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(128)]),
                    ]), "required": .array([.string("key")])]),
                    "outputSchema": .object([
                        "type": .string("object"), "properties": .object([
                            "key": .object(["type": .string("string")]), "status": .object(["type": .string("string"), "enum": .array(["saved", "cancelled"].map(JSONValue.string))]),
                        ]), "required": .array(["key", "status"].map(JSONValue.string)), "additionalProperties": .bool(false),
                    ]),
                ])),
                ("ox.secret.delete", .object([
                    "description": .string(ModelGuidance.text("ox.secret.delete")),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([
                        "key": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(128)]),
                    ]), "required": .array([.string("key")])]),
                    "outputSchema": .object([
                        "type": .string("object"), "properties": .object([
                            "key": .object(["type": .string("string")]), "status": .object(["type": .string("string"), "enum": .array(["deleted", "cancelled"].map(JSONValue.string))]),
                        ]), "required": .array(["key", "status"].map(JSONValue.string)), "additionalProperties": .bool(false),
                    ]),
                ])),
            ]
        },
        installNatives: { context, environment in
            let operation: @convention(block) (String, JSValue, String) -> JSValue = { name, arguments, purpose in
                let value = jsValueToJSON(arguments) ?? .object([:])
                return environment.call(suspendingTimeout: name != "list") {
                    try await $0.secretOperation(name: name, arguments: value, purpose: purpose)
                }
            }
            context.setObject(operation, forKeyedSubscript: "__nativeSecretOperation" as NSString)
        },
        jsFragment: """
          list: value => { const options = __oxOptions(value, 'ox.secret.list'); return __nativeSecretOperation('list', options, String(options.purpose)); },
          add: value => { const options = __oxOptions(value, 'ox.secret.add'); return __nativeSecretOperation('add', options, String(options.purpose)); },
          delete: value => { const options = __oxOptions(value, 'ox.secret.delete'); return __nativeSecretOperation('delete', options, String(options.purpose)); }
        """
    )
}

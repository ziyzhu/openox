import Foundation
import JavaScriptCore

nonisolated enum OxSecret {
    static let function = OxFunction(
        namespace: "secret",
        schema: {
            [
                ("ox.secret.list", .object([
                    "description": .string("List named secrets and their availability without reading values: `await ox.secret.list({ purpose })`."),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
                    "outputSchema": .object(["description": .string("Array of keys and availability states; never values.")]),
                ])),
                ("ox.secret.add", .object([
                    "description": .string("Ask the person to add or replace a named JSON secret in a native inline card: `await ox.secret.add({ key, purpose })`. The value is never a JavaScript argument or result."),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([
                        "key": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(128)]),
                    ]), "required": .array([.string("key")])]),
                    "outputSchema": .object(["description": .string("Key and saved or cancelled status.")]),
                ])),
                ("ox.secret.delete", .object([
                    "description": .string("Ask the person to delete a secret and clear its connections: `await ox.secret.delete({ key, purpose })`."),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([
                        "key": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(128)]),
                    ]), "required": .array([.string("key")])]),
                    "outputSchema": .object(["description": .string("Key and deleted or cancelled status.")]),
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

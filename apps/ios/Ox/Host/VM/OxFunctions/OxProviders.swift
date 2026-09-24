import Foundation
import JavaScriptCore

nonisolated enum OxProviders {
    static let operations: [(String, String)] = [
        ("default", "Return a read-only copy of bundled provider definitions. Does not read or change the active catalog or credentials. Save a definition explicitly to restore or customize a default."),
        ("list", "List provider summaries, model counts, and authentication status. Never returns credentials."),
        ("get", "Read one complete provider definition by id. Models are declared tool-capable entries."),
        ("validate", "Validate a complete provider document without saving or making network requests. Does not verify credentials or model capabilities."),
        ("save", "Create or replace a complete provider definition. Always validates before saving. Models are supplied directly; no discovery is performed."),
        ("delete", "Remove a saved provider definition and clear its local credentials. Removing an override restores the bundled default; removing an added provider removes it entirely. Unmodified bundled defaults cannot be deleted. Requires approval."),
        ("authenticate", "Present the same provider authentication UI used in Settings and wait for completion. Credentials are entered by the user and never passed to JavaScript. Returns status authenticated, credential-stored, or not-required; throws on cancellation or failure."),
        ("connect", "Connect a provider to an existing Secret entry or its managed OAuth flow: `await ox.provider.connect({ id, credential: { kind: 'secret', secretKey } | { kind: 'oauth' }, purpose })`. The agent never receives credential values. A Secret binding requires native destination confirmation."),
        ("deauthenticate", "Clear a provider's local credentials and account authentication. Does not revoke access at the provider."),
    ]

    static let function = OxFunction(
        namespace: "provider",
        schema: {
            operations.map { operation, description in
                let fields: [String: JSONValue]
                if ["save", "validate"].contains(operation) { fields = ["provider": ProviderDefinition.schema] }
                else if operation == "connect" {
                    fields = [
                        "id": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(200)]),
                        "credential": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "kind": .object(["type": .string("string"),
                                                 "enum": .array([.string("secret"), .string("oauth")])]),
                                "secretKey": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(128)]),
                            ]),
                            "required": .array([.string("kind")]),
                            "additionalProperties": .bool(false),
                        ]),
                    ]
                }
                else if operation == "list" || operation == "default" { fields = [:] }
                else { fields = ["id": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(200)])] }
                return ("ox.provider.\(operation)", .object([
                    "description": .string(description),
                    "inputSchema": .object([
                        "type": .string("object"), "properties": .object(fields),
                        "required": .array(fields.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false),
                    ]),
                    "outputSchema": operation == "default" ? .object(["type": .string("array"), "items": ProviderDefinition.schema]) : operation == "get" ? ProviderDefinition.schema : .object(["description": .string(operation == "list" ? "Array of provider summaries." : "Operation result with provider id and status.")]),
                ]))
            }
        },
        installNatives: { context, environment in
            let operation: @convention(block) (String, JSValue, String) -> JSValue = { name, arguments, purpose in
                let value = jsValueToJSON(arguments) ?? .object([:])
                return environment.call(suspendingTimeout: true) { try await $0.providerOperation(name: name, arguments: value, purpose: purpose) }
            }
            context.setObject(operation, forKeyedSubscript: "__nativeProviderOperation" as NSString)
        },
        jsFragment: operations.map { name, _ in
            "\(name): value => { const options = __oxOptions(value, 'ox.provider.\(name)'); return __nativeProviderOperation('\(name)', options, String(options.purpose)); }"
        }.joined(separator: ",\n")
    )
}

import Foundation
import JavaScriptCore

nonisolated enum OxProviders {
    private static let nullableString = JSONValue.object(["type": .array([.string("string"), .string("null")])])
    private static let providerSummarySchema = JSONValue.object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([
            "id", "name", "source", "api", "url", "website", "regions", "inferenceLocation", "models",
            "availableModels", "authentication", "access", "capabilities", "gettingStarted",
        ].map(JSONValue.string)),
        "properties": .object([
            "id": .object(["type": .string("string")]),
            "name": .object(["type": .string("string")]),
            "source": .object(["type": .string("string"), "enum": .array(["bundled", "override", "added", "web-service"].map(JSONValue.string))]),
            "api": .object(["type": .string("string"), "enum": .array(LLMWireProtocol.allProviderInformationValues.map(JSONValue.string))]),
            "url": .object(["type": .string("string")]),
            "website": nullableString,
            "regions": .object(["type": .string("array"), "items": .object(["type": .string("string"), "enum": .array(LLMRegion.allCases.map { .string($0.rawValue) })])]),
            "inferenceLocation": .object(["type": .string("string"), "enum": .array(["remote", "user-hosted", "on-device"].map(JSONValue.string))]),
            "models": .object(["type": .string("integer"), "minimum": .int(0)]),
            "availableModels": .object(["type": .string("integer"), "minimum": .int(0)]),
            "authentication": .object(["type": .string("string"), "enum": .array(["authenticated", "credential-stored", "required", "optional", "not-required", "browser-session", "unavailable"].map(JSONValue.string))]),
            "access": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array(["methods", "credentialKind", "acceptsSecret", "optional", "notice"].map(JSONValue.string)),
                "properties": .object([
                    "methods": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "credentialKind": nullableString,
                    "acceptsSecret": .object(["type": .string("boolean")]),
                    "optional": .object(["type": .string("boolean")]),
                    "notice": nullableString,
                ]),
            ]),
            "capabilities": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array(["supportsTools", "canLoadModels", "reasoningPolicy"].map(JSONValue.string)),
                "properties": .object([
                    "supportsTools": .object(["type": .string("boolean")]),
                    "canLoadModels": .object(["type": .string("boolean")]),
                    "reasoningPolicy": .object(["type": .string("string"), "enum": .array(["none", "minimal", "low", "providerDefault", "unavailable"].map(JSONValue.string))]),
                ]),
            ]),
            "gettingStarted": .object([
                "type": .array([.string("object"), .string("null")]),
                "additionalProperties": .bool(false),
                "required": .array(["summary", "priority", "regions"].map(JSONValue.string)),
                "properties": .object([
                    "summary": .object(["type": .string("string")]),
                    "priority": .object(["type": .string("integer")]),
                    "regions": .object(["type": .string("array"), "items": .object(["type": .string("string"), "enum": .array(LLMRegion.allCases.map { .string($0.rawValue) })])]),
                ]),
            ]),
        ]),
    ])

    static let operations: [(String, String)] = [
        ("default", ModelGuidance.text("ox.provider.default")),
        ("list", ModelGuidance.text("ox.provider.list")),
        ("get", ModelGuidance.text("ox.provider.get")),
        ("validate", ModelGuidance.text("ox.provider.validate")),
        ("save", ModelGuidance.text("ox.provider.save")),
        ("delete", ModelGuidance.text("ox.provider.delete")),
        ("authenticate", ModelGuidance.text("ox.provider.authenticate")),
        ("connect", ModelGuidance.text("ox.provider.connect")),
        ("deauthenticate", ModelGuidance.text("ox.provider.deauthenticate")),
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
                    "outputSchema": operation == "default" ? .object(["type": .string("array"), "items": ProviderDefinition.schema]) : operation == "list" ? .object(["type": .string("array"), "items": providerSummarySchema]) : operation == "get" ? ProviderDefinition.schema : .object(["description": .string("Operation result with provider id and status.")]),
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

private extension LLMWireProtocol {
    static let allProviderInformationValues = [
        openAIResponses.rawValue,
        openAIChatCompletions.rawValue,
        anthropicMessages.rawValue,
        geminiGenerateContent.rawValue,
        web.rawValue,
    ]
}

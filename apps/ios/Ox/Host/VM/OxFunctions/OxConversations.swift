import Foundation
import JavaScriptCore

nonisolated enum OxConversations {
    static let function = OxFunction(
        namespace: "conversation",
        schema: {
            [
                ("ox.conversation.model", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.model")),
                    "inputSchema": object([:]),
                    "outputSchema": modelInformation,
                ])),
                ("ox.conversation.setModel", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.setModel")),
                    "inputSchema": object(["selection": modelSelection], required: ["selection"]),
                    "outputSchema": object([
                        "status": enumeration(["pending", "applied"]),
                        "selection": modelSelection,
                        "changed": boolean,
                    ], required: ["status", "selection", "changed"]),
                ])),
                ("ox.conversation.rename", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.rename")),
                    "inputSchema": object([
                        "title": .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(60),
                            "description": .string("A concise 1–10 word title describing the conversation's purpose."),
                        ]),
                    ], required: ["title"]),
                    "outputSchema": object([
                        "renamed": boolean,
                        "title": string,
                    ], required: ["renamed", "title"]),
                ])),
                ("ox.conversation.start", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.start")),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "prompt": .object(["type": .string("string"), "minLength": .int(1)]),
                            "title": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("prompt")]),
                    ]),
                    "outputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["id": .object(["type": .string("string"), "format": .string("uuid")])]),
                        "required": .array([.string("id")]),
                    ]),
                ])),
                ("ox.conversation.delete", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.delete")),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["id": .object(["type": .string("string"), "format": .string("uuid")])]),
                        "required": .array([.string("id")]),
                    ]),
                    "outputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object(["type": .string("string")]),
                            "deleted": .object(["type": .string("boolean")]),
                        ]),
                        "required": .array([.string("id"), .string("deleted")]),
                    ]),
                ])),
            ]
        },
        installNatives: { context, environment in
            let model: @convention(block) (String) -> JSValue = { purpose in
                environment.call { try await $0.appModel(purpose: purpose) }
            }
            context.setObject(model, forKeyedSubscript: "__nativeConversationModel" as NSString)
            let setModel: @convention(block) (JSValue, String) -> JSValue = { options, purpose in
                let value = jsValueToJSON(options) ?? .object([:])
                return environment.call(suspendingTimeout: true) { try await $0.setAppModel(options: value, purpose: purpose) }
            }
            context.setObject(setModel, forKeyedSubscript: "__nativeConversationSetModel" as NSString)
            let rename: @convention(block) (String, String) -> JSValue = { title, purpose in
                environment.call { try await $0.renameChat(title: title, purpose: purpose) }
            }
            context.setObject(rename, forKeyedSubscript: "__nativeConversationRename" as NSString)
            let start: @convention(block) (String, String, String) -> JSValue = { prompt, title, purpose in
                environment.call(suspendingTimeout: true) { try await $0.startConversation(prompt: prompt, title: title, purpose: purpose) }
            }
            context.setObject(start, forKeyedSubscript: "__nativeConversationStart" as NSString)
            let delete: @convention(block) (String, String) -> JSValue = { id, purpose in
                environment.call(suspendingTimeout: true) { try await $0.deleteConversation(id: id, purpose: purpose) }
            }
            context.setObject(delete, forKeyedSubscript: "__nativeConversationDelete" as NSString)
        },
        jsFragment: """
        model: value => { const options = __oxOptions(value, 'ox.conversation.model'); return __nativeConversationModel(String(options.purpose)); },
        setModel: value => { const { purpose, ...options } = __oxOptions(value, 'ox.conversation.setModel'); return __nativeConversationSetModel(options, String(purpose)); },
        rename: value => { const options = __oxOptions(value, 'ox.conversation.rename'); return __nativeConversationRename(String(options.title), String(options.purpose)); },
        start: value => { const options = __oxOptions(value, 'ox.conversation.start'); return __nativeConversationStart(String(options.prompt), String(options.title ?? ''), String(options.purpose)); },
        delete: value => { const options = __oxOptions(value, 'ox.conversation.delete'); return __nativeConversationDelete(String(options.id), String(options.purpose)); }
        """
    )

    private static let string = JSONValue.object(["type": .string("string")])
    private static let boolean = JSONValue.object(["type": .string("boolean")])
    static let namedValue = object([
        "id": string,
        "name": string,
    ], required: ["id", "name"])
    static let authenticationInformation = object([
        "method": enumeration(["apiKey", "subscriptionKey", "bearerToken", "subscription", "none"]),
        "status": enumeration(["ready", "missingCredential", "signedOut", "notRequired"]),
        "settingsPath": string,
    ], required: ["method", "status", "settingsPath"])
    static let modelSelection = object([
        "provider": boundedString(maximum: 100, description: "Exact provider ID from ox.provider.list."),
        "model": boundedString(maximum: 500, description: "Exact available picker model ID from ox.provider.get, not its wire ID."),
        "thinkingLevel": nullable(boundedString(maximum: 100, description: "Supported thinking level; null selects the model's lowest level. Omission preserves it for the same model.")),
    ], required: ["provider", "model"])
    private static let modelInformation = object([
        "provider": namedValue,
        "model": namedValue,
        "supportsTools": boolean,
        "thinkingLevel": nullable(string),
        "change": nullable(object([
            "status": enumeration(["pending", "applied", "failed", "cancelled"]),
            "selection": modelSelection,
            "error": nullable(string),
        ], required: ["status", "selection", "error"])),
        "authentication": authenticationInformation,
    ], required: ["provider", "model", "supportsTools", "authentication"])

    private static func nullable(_ value: JSONValue) -> JSONValue {
        var fields = value.objectValue ?? [:]
        fields["type"] = .array([fields["type"] ?? .string("object"), .string("null")])
        return .object(fields)
    }

    private static func enumeration(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }

    private static func boundedString(maximum: Int, description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "minLength": .int(1),
            "maxLength": .int(maximum),
            "description": .string(description),
        ])
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
            "required": .array(required.map(JSONValue.string)),
        ])
    }
}

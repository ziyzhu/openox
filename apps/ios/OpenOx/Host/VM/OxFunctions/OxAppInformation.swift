import Foundation
import JavaScriptCore

nonisolated enum OxAppInformation {
    static let function = OxFunction(
        namespace: "app",
        schema: {
            [(
                "ox.app.inspect",
                .object([
                    "description": .string("Inspect Ox's current app identity, model and authentication readiness, profile storage, and optional setup state: `await ox.app.inspect({ purpose })`. Call this only when the user asks about Ox itself, setup, settings, configuration, the current model, storage, notifications, Siri, or app version. Returns status only and never returns credentials, account labels, internal paths, or profile identifiers."),
                    "inputSchema": object([:]),
                    "outputSchema": object([
                        "app": object([
                            "name": string,
                            "version": string,
                            "build": string,
                            "region": enumeration(["global", "china"]),
                            "language": string,
                        ], required: ["name", "version", "build", "region", "language"]),
                        "model": object([
                            "provider": namedValue,
                            "model": namedValue,
                            "supportsTools": boolean,
                            "authentication": object([
                                "method": enumeration(["apiKey", "subscriptionKey", "bearerToken", "subscription", "none"]),
                                "status": enumeration(["ready", "missingCredential", "signedOut", "notRequired"]),
                                "settingsPath": string,
                            ], required: ["method", "status", "settingsPath"]),
                        ], required: ["provider", "model", "supportsTools", "authentication"]),
                        "profile": .object([
                            "type": .array([.string("object"), .string("null")]),
                            "description": .string("The active profile without its identifier or filesystem path."),
                            "properties": .object([
                                "name": string,
                                "storage": enumeration(["local", "iCloud", "external"]),
                                "settingsPath": string,
                            ]),
                            "required": .array([.string("name"), .string("storage"), .string("settingsPath")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "setup": object([
                            "coreStatus": enumeration(["ready", "actionRequired"]),
                            "notifications": object([
                                "status": enumeration(["granted", "denied", "notDetermined"]),
                                "required": boolean,
                                "settingsPath": string,
                            ], required: ["status", "required", "settingsPath"]),
                            "siri": object([
                                "status": enumeration(["notInspectable"]),
                                "required": boolean,
                                "settingsPath": string,
                            ], required: ["status", "required", "settingsPath"]),
                            "tourSettingsPath": string,
                        ], required: ["coreStatus", "notifications", "siri", "tourSettingsPath"]),
                    ], required: ["app", "model", "profile", "setup"]),
                ])
            ), (
                "ox.app.renameChat",
                .object([
                    "description": .string("Keep the current chat's title aligned with its purpose: `await ox.app.renameChat({ title, purpose })`. In a persisted chat, call this only when a new or updated title would make the chat's purpose meaningfully clearer. Do not call it merely because the user sent another message or when the current title remains accurate. The title must contain 1–10 words and at most 60 characters. A previous agent title may be updated; titles set by the user or an import are preserved. Returns the current explicit title and whether it changed."),
                    "inputSchema": object([
                        "title": .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(60),
                            "description": .string("A concise 1–10 word title describing the chat's purpose."),
                        ]),
                    ], required: ["title"]),
                    "outputSchema": object([
                        "renamed": boolean,
                        "title": string,
                    ], required: ["renamed", "title"]),
                ])
            )]
        },
        installNatives: { context, env in
            let inspect: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.inspectApp(purpose: purpose) }
            }
            let renameChat: @convention(block) (String, String) -> JSValue = { title, purpose in
                env.call { try await $0.renameChat(title: title, purpose: purpose) }
            }
            context.setObject(inspect as AnyObject, forKeyedSubscript: "__nativeAppInspect" as NSString)
            context.setObject(renameChat as AnyObject, forKeyedSubscript: "__nativeAppRenameChat" as NSString)
        },
        jsFragment: """
          inspect: (value) => { const options = __oxOptions(value, 'ox.app.inspect'); return __nativeAppInspect(String(options.purpose)); },
          renameChat: (value) => { const options = __oxOptions(value, 'ox.app.renameChat'); return __nativeAppRenameChat(String(options.title), String(options.purpose)); }
        """
    )

    private static let string = JSONValue.object(["type": .string("string")])
    private static let boolean = JSONValue.object(["type": .string("boolean")])
    private static let namedValue = object([
        "id": string,
        "name": string,
    ], required: ["id", "name"])

    private static func enumeration(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }
}

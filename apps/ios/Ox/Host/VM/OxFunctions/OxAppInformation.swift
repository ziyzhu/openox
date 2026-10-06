import Foundation
import JavaScriptCore

nonisolated enum OxAppInformation {
    static let function = OxFunction(
        namespace: "app",
        schema: {
            [(
                "ox.app.info",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.info")),
                    "inputSchema": object([:]),
                    "outputSchema": object([
                        "name": string,
                        "version": string,
                        "build": string,
                        "region": enumeration(["global", "china"]),
                    ], required: ["name", "version", "build", "region"]),
                ])
            ), (
                "ox.app.profile",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.profile")),
                    "inputSchema": object([:]),
                    "outputSchema": nullable(object([
                        "name": string,
                        "storage": enumeration(["local", "iCloud", "external"]),
                    ], required: ["name", "storage"])),
                ])
            ), (
                "ox.app.profiles",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.profiles")),
                    "inputSchema": object([:]),
                    "outputSchema": object([
                        "profiles": array(object([
                            "name": string,
                            "storage": enumeration(["local", "iCloud", "external"]),
                            "active": boolean,
                        ], required: ["name", "storage", "active"]), maximum: 100),
                        "truncated": boolean,
                    ], required: ["profiles", "truncated"]),
                ])
            ), (
                "ox.app.notifications",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.notifications")),
                    "inputSchema": object([:]),
                    "outputSchema": object([
                        "status": enumeration(["granted", "denied", "notDetermined"]),
                    ], required: ["status"]),
                ])
            ), (
                "ox.app.language",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.language")),
                    "inputSchema": object([:]),
                    "outputSchema": object([
                        "selection": enumeration(["system", "en", "zh-Hans"]),
                        "locale": string,
                    ], required: ["selection", "locale"]),
                ])
            ), (
                "ox.app.theme",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.theme")),
                    "inputSchema": object([:]),
                    "outputSchema": object([
                        "selection": enumeration(["creatorPick", "light", "dark"]),
                        "appearance": enumeration(["light", "dark"]),
                    ], required: ["selection", "appearance"]),
                ])
            ), (
                "ox.app.model",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.model")),
                    "inputSchema": object([:]),
                    "outputSchema": modelInformation,
                ])
            ), (
                "ox.app.defaultModel",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.defaultModel")),
                    "inputSchema": object([:]),
                    "outputSchema": object([
                        "configured": boolean,
                        "region": enumeration(["global", "china"]),
                        "provider": namedValue,
                        "model": namedValue,
                        "thinkingLevel": nullable(string),
                        "supportsTools": boolean,
                        "authentication": authenticationInformation,
                    ], required: ["configured", "region", "provider", "model", "thinkingLevel", "supportsTools", "authentication"]),
                ])
            ), (
                "ox.app.actionPolicies",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.actionPolicies")),
                    "inputSchema": object([
                        "source": boundedString(maximum: 500, description: "Exact Action source identifier."),
                        "action": boundedString(maximum: 500, description: "Exact Action identifier to filter and resolve."),
                        "query": boundedString(maximum: 200, description: "Case-insensitive substring of an Action or source identifier."),
                        "limit": integer(minimum: 1, maximum: 100, description: "Maximum overrides; defaults to 50."),
                    ]),
                    "outputSchema": object([
                        "defaultPolicy": nullable(actionPolicy),
                        "resolved": nullable(object([
                            "action": string,
                            "source": string,
                            "policy": actionPolicy,
                            "inheritedFrom": enumeration(["action", "source", "default", "actionDefault"]),
                        ], required: ["action", "source", "policy", "inheritedFrom"])),
                        "overrides": array(object([
                            "scope": enumeration(["source", "action"]),
                            "id": string,
                            "source": string,
                            "policy": actionPolicy,
                        ], required: ["scope", "id", "source", "policy"]), maximum: 100),
                        "truncated": boolean,
                    ], required: ["defaultPolicy", "resolved", "overrides", "truncated"]),
                ])
            ), (
                "ox.app.repositories",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.repositories")),
                    "inputSchema": object([:]),
                    "outputSchema": object([
                        "status": enumeration(["idle", "syncing", "ready", "failed"]),
                        "repositories": array(object([
                            "id": string,
                            "name": string,
                            "provenance": enumeration(["bundled", "local", "development", "remote"]),
                            "enabled": boolean,
                            "state": enumeration(["ready", "failed"]),
                            "serviceCount": integer(minimum: 0),
                            "skillCount": integer(minimum: 0),
                        ], required: ["id", "name", "provenance", "enabled", "state", "serviceCount", "skillCount"]), maximum: 50),
                        "truncated": boolean,
                    ], required: ["status", "repositories", "truncated"]),
                ])
            ), (
                "ox.app.logs",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.logs")),
                    "inputSchema": object([
                        "level": .object([
                            "type": .string("string"),
                            "enum": .array(["debug", "info", "warning", "error"].map(JSONValue.string)),
                            "description": .string("Minimum severity; defaults to debug."),
                        ]),
                        "category": .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(80),
                            "description": .string("Exact category, such as Agent, Service, Network, or Session."),
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(200),
                            "description": .string("Case-insensitive substring of the redacted message."),
                        ]),
                        "since": .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(40),
                            "description": .string("Inclusive ISO 8601 timestamp with a time zone."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "minimum": .int(1),
                            "maximum": .int(100),
                            "description": .string("Maximum entries; defaults to 50. Results also have a 64 KiB entry budget."),
                        ]),
                    ]),
                    "outputSchema": object([
                        "entries": .object([
                            "type": .string("array"),
                            "items": object([
                                "timestamp": string,
                                "level": enumeration(["debug", "info", "warning", "error"]),
                                "category": string,
                                "message": string,
                                "truncated": boolean,
                            ], required: ["timestamp", "level", "category", "message", "truncated"]),
                        ]),
                        "truncated": boolean,
                        "oldestAvailable": nullable(string),
                    ], required: ["entries", "truncated", "oldestAvailable"]),
                ])
            ), (
                "ox.app.renameChat",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.renameChat")),
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
            let info: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appInfo(purpose: purpose) }
            }
            let profile: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appProfile(purpose: purpose) }
            }
            let profiles: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appProfiles(purpose: purpose) }
            }
            let notifications: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appNotifications(purpose: purpose) }
            }
            let language: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appLanguage(purpose: purpose) }
            }
            let theme: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appTheme(purpose: purpose) }
            }
            let model: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appModel(purpose: purpose) }
            }
            let defaultModel: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appDefaultModel(purpose: purpose) }
            }
            let actionPolicies: @convention(block) (JSValue, String) -> JSValue = { options, purpose in
                let value = jsValueToJSON(options)
                return env.call { try await $0.appActionPolicies(options: value, purpose: purpose) }
            }
            let repositories: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appRepositories(purpose: purpose) }
            }
            let logs: @convention(block) (JSValue, String) -> JSValue = { options, purpose in
                let value = jsValueToJSON(options)
                return env.call(suspendingTimeout: true) { try await $0.appLogs(options: value, purpose: purpose) }
            }
            let renameChat: @convention(block) (String, String) -> JSValue = { title, purpose in
                env.call { try await $0.renameChat(title: title, purpose: purpose) }
            }
            context.setObject(info as AnyObject, forKeyedSubscript: "__nativeAppInfo" as NSString)
            context.setObject(profile as AnyObject, forKeyedSubscript: "__nativeAppProfile" as NSString)
            context.setObject(profiles as AnyObject, forKeyedSubscript: "__nativeAppProfiles" as NSString)
            context.setObject(notifications as AnyObject, forKeyedSubscript: "__nativeAppNotifications" as NSString)
            context.setObject(language as AnyObject, forKeyedSubscript: "__nativeAppLanguage" as NSString)
            context.setObject(theme as AnyObject, forKeyedSubscript: "__nativeAppTheme" as NSString)
            context.setObject(model as AnyObject, forKeyedSubscript: "__nativeAppModel" as NSString)
            context.setObject(defaultModel as AnyObject, forKeyedSubscript: "__nativeAppDefaultModel" as NSString)
            context.setObject(actionPolicies as AnyObject, forKeyedSubscript: "__nativeAppActionPolicies" as NSString)
            context.setObject(repositories as AnyObject, forKeyedSubscript: "__nativeAppRepositories" as NSString)
            context.setObject(logs as AnyObject, forKeyedSubscript: "__nativeAppLogs" as NSString)
            context.setObject(renameChat as AnyObject, forKeyedSubscript: "__nativeAppRenameChat" as NSString)
        },
        jsFragment: """
          info: (value) => { const options = __oxOptions(value, 'ox.app.info'); return __nativeAppInfo(String(options.purpose)); },
          profile: (value) => { const options = __oxOptions(value, 'ox.app.profile'); return __nativeAppProfile(String(options.purpose)); },
          profiles: (value) => { const options = __oxOptions(value, 'ox.app.profiles'); return __nativeAppProfiles(String(options.purpose)); },
          notifications: (value) => { const options = __oxOptions(value, 'ox.app.notifications'); return __nativeAppNotifications(String(options.purpose)); },
          language: (value) => { const options = __oxOptions(value, 'ox.app.language'); return __nativeAppLanguage(String(options.purpose)); },
          theme: (value) => { const options = __oxOptions(value, 'ox.app.theme'); return __nativeAppTheme(String(options.purpose)); },
          model: (value) => { const options = __oxOptions(value, 'ox.app.model'); return __nativeAppModel(String(options.purpose)); },
          defaultModel: (value) => { const options = __oxOptions(value, 'ox.app.defaultModel'); return __nativeAppDefaultModel(String(options.purpose)); },
          actionPolicies: (value) => { const { purpose, ...options } = __oxOptions(value, 'ox.app.actionPolicies'); return __nativeAppActionPolicies(options, String(purpose)); },
          repositories: (value) => { const options = __oxOptions(value, 'ox.app.repositories'); return __nativeAppRepositories(String(options.purpose)); },
          logs: (value) => { const { purpose, ...options } = __oxOptions(value, 'ox.app.logs'); return __nativeAppLogs(options, String(purpose)); },
          renameChat: (value) => { const options = __oxOptions(value, 'ox.app.renameChat'); return __nativeAppRenameChat(String(options.title), String(options.purpose)); }
        """
    )

    private static let string = JSONValue.object(["type": .string("string")])
    private static let boolean = JSONValue.object(["type": .string("boolean")])
    private static let namedValue = object([
        "id": string,
        "name": string,
    ], required: ["id", "name"])
    private static let actionPolicy = enumeration(["ask", "allow", "block"])
    private static let authenticationInformation = object([
        "method": enumeration(["apiKey", "subscriptionKey", "bearerToken", "subscription", "none"]),
        "status": enumeration(["ready", "missingCredential", "signedOut", "notRequired"]),
        "settingsPath": string,
    ], required: ["method", "status", "settingsPath"])
    private static let modelInformation = object([
        "provider": namedValue,
        "model": namedValue,
        "supportsTools": boolean,
        "authentication": authenticationInformation,
    ], required: ["provider", "model", "supportsTools", "authentication"])

    private static func nullable(_ value: JSONValue) -> JSONValue {
        var fields = value.objectValue ?? [:]
        fields["type"] = .array([fields["type"] ?? .string("object"), .string("null")])
        return .object(fields)
    }

    private static func enumeration(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    private static func boundedString(maximum: Int, description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "minLength": .int(1),
            "maxLength": .int(maximum),
            "description": .string(description),
        ])
    }

    private static func integer(minimum: Int, maximum: Int? = nil, description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("integer"),
            "minimum": .int(minimum),
        ]
        if let maximum { schema["maximum"] = .int(maximum) }
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    private static func array(_ items: JSONValue, maximum: Int) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": items,
            "maxItems": .int(maximum),
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

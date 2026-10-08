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
                "ox.app.setLanguage",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.setLanguage")),
                    "inputSchema": object([
                        "selection": enumeration(["system", "en", "zh-Hans"]),
                    ], required: ["selection"]),
                    "outputSchema": object([
                        "selection": enumeration(["system", "en", "zh-Hans"]),
                        "locale": string,
                        "changed": boolean,
                    ], required: ["selection", "locale", "changed"]),
                ])
            ), (
                "ox.app.setTheme",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.setTheme")),
                    "inputSchema": object([
                        "selection": enumeration(["creatorPick", "light", "dark"]),
                    ], required: ["selection"]),
                    "outputSchema": object([
                        "selection": enumeration(["creatorPick", "light", "dark"]),
                        "appearance": enumeration(["light", "dark"]),
                        "changed": boolean,
                    ], required: ["selection", "appearance", "changed"]),
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
                "ox.app.setDefaultModel",
                .object([
                    "description": .string(ModelGuidance.text("ox.app.setDefaultModel")),
                    "inputSchema": object(["selection": nullable(modelSelection)], required: ["selection"]),
                    "outputSchema": object([
                        "configured": boolean,
                        "selection": nullable(modelSelection),
                        "changed": boolean,
                    ], required: ["configured", "selection", "changed"]),
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
            let setLanguage: @convention(block) (String, String) -> JSValue = { selection, purpose in
                env.call { try await $0.setAppLanguage(selection: selection, purpose: purpose) }
            }
            let setTheme: @convention(block) (String, String) -> JSValue = { selection, purpose in
                env.call { try await $0.setAppTheme(selection: selection, purpose: purpose) }
            }
            let defaultModel: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appDefaultModel(purpose: purpose) }
            }
            let setDefaultModel: @convention(block) (JSValue, String) -> JSValue = { options, purpose in
                let value = jsValueToJSON(options) ?? .object([:])
                return env.call(suspendingTimeout: true) { try await $0.setAppDefaultModel(options: value, purpose: purpose) }
            }
            let actionPolicies: @convention(block) (JSValue, String) -> JSValue = { options, purpose in
                let value = jsValueToJSON(options)
                return env.call { try await $0.appActionPolicies(options: value, purpose: purpose) }
            }
            let logs: @convention(block) (JSValue, String) -> JSValue = { options, purpose in
                let value = jsValueToJSON(options)
                return env.call(suspendingTimeout: true) { try await $0.appLogs(options: value, purpose: purpose) }
            }
            context.setObject(info as AnyObject, forKeyedSubscript: "__nativeAppInfo" as NSString)
            context.setObject(profile as AnyObject, forKeyedSubscript: "__nativeAppProfile" as NSString)
            context.setObject(profiles as AnyObject, forKeyedSubscript: "__nativeAppProfiles" as NSString)
            context.setObject(notifications as AnyObject, forKeyedSubscript: "__nativeAppNotifications" as NSString)
            context.setObject(language as AnyObject, forKeyedSubscript: "__nativeAppLanguage" as NSString)
            context.setObject(theme as AnyObject, forKeyedSubscript: "__nativeAppTheme" as NSString)
            context.setObject(setLanguage as AnyObject, forKeyedSubscript: "__nativeAppSetLanguage" as NSString)
            context.setObject(setTheme as AnyObject, forKeyedSubscript: "__nativeAppSetTheme" as NSString)
            context.setObject(defaultModel as AnyObject, forKeyedSubscript: "__nativeAppDefaultModel" as NSString)
            context.setObject(setDefaultModel as AnyObject, forKeyedSubscript: "__nativeAppSetDefaultModel" as NSString)
            context.setObject(actionPolicies as AnyObject, forKeyedSubscript: "__nativeAppActionPolicies" as NSString)
            context.setObject(logs as AnyObject, forKeyedSubscript: "__nativeAppLogs" as NSString)
        },
        jsFragment: """
          info: (value) => { const options = __oxOptions(value, 'ox.app.info'); return __nativeAppInfo(String(options.purpose)); },
          profile: (value) => { const options = __oxOptions(value, 'ox.app.profile'); return __nativeAppProfile(String(options.purpose)); },
          profiles: (value) => { const options = __oxOptions(value, 'ox.app.profiles'); return __nativeAppProfiles(String(options.purpose)); },
          notifications: (value) => { const options = __oxOptions(value, 'ox.app.notifications'); return __nativeAppNotifications(String(options.purpose)); },
          language: (value) => { const options = __oxOptions(value, 'ox.app.language'); return __nativeAppLanguage(String(options.purpose)); },
          theme: (value) => { const options = __oxOptions(value, 'ox.app.theme'); return __nativeAppTheme(String(options.purpose)); },
          setLanguage: (value) => { const options = __oxOptions(value, 'ox.app.setLanguage'); return __nativeAppSetLanguage(String(options.selection), String(options.purpose)); },
          setTheme: (value) => { const options = __oxOptions(value, 'ox.app.setTheme'); return __nativeAppSetTheme(String(options.selection), String(options.purpose)); },
          defaultModel: (value) => { const options = __oxOptions(value, 'ox.app.defaultModel'); return __nativeAppDefaultModel(String(options.purpose)); },
          setDefaultModel: (value) => { const { purpose, ...options } = __oxOptions(value, 'ox.app.setDefaultModel'); return __nativeAppSetDefaultModel(options, String(purpose)); },
          actionPolicies: (value) => { const { purpose, ...options } = __oxOptions(value, 'ox.app.actionPolicies'); return __nativeAppActionPolicies(options, String(purpose)); },
          logs: (value) => { const { purpose, ...options } = __oxOptions(value, 'ox.app.logs'); return __nativeAppLogs(options, String(purpose)); }
        """
    )

    private static let string = JSONValue.object(["type": .string("string")])
    private static let boolean = JSONValue.object(["type": .string("boolean")])
    private static let namedValue = OxConversations.namedValue
    private static let actionPolicy = enumeration(["ask", "allow", "block"])
    private static let authenticationInformation = OxConversations.authenticationInformation
    private static let modelSelection = OxConversations.modelSelection

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

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
                            "maxLength": .int(50),
                            "description": .string("A concise title of at most 50 characters describing the conversation's purpose."),
                        ]),
                    ], required: ["title"]),
                    "outputSchema": object([
                        "renamed": boolean,
                        "title": string,
                    ], required: ["renamed", "title"]),
                ])),
                ("ox.conversation.start", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.start")),
                    "inputSchema": object([
                        "prompt": boundedString(maximum: 20_000, description: "Self-contained instructions for the child conversation."),
                        "title": boundedString(maximum: 50, description: "A concise title of at most 50 characters."),
                        "services": .object(["type": .string("array"), "items": string, "maxItems": .int(10)]),
                        "agent": boundedString(maximum: 100, description: "Name of a remote agent from Settings → Agents. Omit to run on this device."),
                        "folder": boundedString(maximum: 4096, description: "Workspace folder on the agent's computer; defaults to its first allowed folder."),
                    ], required: ["prompt"]),
                    "outputSchema": child,
                ])),
                ("ox.conversation.send", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.send")),
                    "inputSchema": object(["id": uuid, "text": boundedString(maximum: 20_000, description: "Message for the child conversation.")], required: ["id", "text"]),
                    "outputSchema": child,
                ])),
                ("ox.conversation.wait", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.wait")),
                    "inputSchema": object(["id": uuid, "timeoutSeconds": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(600)])], required: ["id"]),
                    "outputSchema": childWith(["reply": string]),
                ])),
                ("ox.conversation.read", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.read")),
                    "inputSchema": object(["id": uuid, "after": string], required: ["id"]),
                    "outputSchema": childWith([
                        "messages": .object(["type": .string("array"), "items": object([
                            "id": string, "role": enumeration(["user", "assistant"]), "text": string, "at": string,
                        ], required: ["id", "role", "text", "at"])]),
                        "cursor": nullable(string),
                    ], required: ["messages", "cursor"]),
                ])),
                ("ox.conversation.stop", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.stop")),
                    "inputSchema": object(["id": uuid], required: ["id"]),
                    "outputSchema": object(["id": string, "wasRunning": boolean], required: ["id", "wasRunning"]),
                ])),
                ("ox.conversation.children", .object([
                    "description": .string(ModelGuidance.text("ox.conversation.children")),
                    "inputSchema": object([:]),
                    "outputSchema": object(["children": .object(["type": .string("array"), "items": child])], required: ["children"]),
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
                environment.call { try await $0.renameConversation(title: title, purpose: purpose) }
            }
            context.setObject(rename, forKeyedSubscript: "__nativeConversationRename" as NSString)
            let delete: @convention(block) (String, String) -> JSValue = { id, purpose in
                environment.call(suspendingTimeout: true) { try await $0.deleteConversation(id: id, purpose: purpose) }
            }
            context.setObject(delete, forKeyedSubscript: "__nativeConversationDelete" as NSString)
            let start: @convention(block) (JSValue, String) -> JSValue = { options, purpose in
                let value = jsValueToJSON(options) ?? .object([:])
                return environment.call(suspendingTimeout: true) { try await $0.startChildConversation(options: value, purpose: purpose) }
            }
            context.setObject(start, forKeyedSubscript: "__nativeConversationStart" as NSString)
            let send: @convention(block) (String, String, String) -> JSValue = { id, text, purpose in
                environment.call { try await $0.sendChildConversation(id: id, text: text, purpose: purpose) }
            }
            context.setObject(send, forKeyedSubscript: "__nativeConversationSend" as NSString)
            let wait: @convention(block) (String, JSValue, String) -> JSValue = { id, timeout, purpose in
                let seconds = timeout.isNumber ? Int(timeout.toInt32()) : nil
                return environment.call(suspendingTimeout: true) { try await $0.waitChildConversation(id: id, timeoutSeconds: seconds, purpose: purpose) }
            }
            context.setObject(wait, forKeyedSubscript: "__nativeConversationWait" as NSString)
            let read: @convention(block) (String, JSValue, String) -> JSValue = { id, after, purpose in
                let cursor = after.isString ? after.toString() : nil
                return environment.call { try await $0.readChildConversation(id: id, after: cursor, purpose: purpose) }
            }
            context.setObject(read, forKeyedSubscript: "__nativeConversationRead" as NSString)
            let stop: @convention(block) (String, String) -> JSValue = { id, purpose in
                environment.call { try await $0.stopChildConversation(id: id, purpose: purpose) }
            }
            context.setObject(stop, forKeyedSubscript: "__nativeConversationStop" as NSString)
            let children: @convention(block) (String) -> JSValue = { purpose in
                environment.call { try await $0.listChildConversations(purpose: purpose) }
            }
            context.setObject(children, forKeyedSubscript: "__nativeConversationChildren" as NSString)
        },
        jsFragment: """
        model: value => { const options = __oxOptions(value, 'ox.conversation.model'); return __nativeConversationModel(String(options.purpose)); },
        setModel: value => { const { purpose, ...options } = __oxOptions(value, 'ox.conversation.setModel'); return __nativeConversationSetModel(options, String(purpose)); },
        rename: value => { const options = __oxOptions(value, 'ox.conversation.rename'); return __nativeConversationRename(String(options.title), String(options.purpose)); },
        delete: value => { const options = __oxOptions(value, 'ox.conversation.delete'); return __nativeConversationDelete(String(options.id), String(options.purpose)); },
        start: value => { const { purpose, ...options } = __oxOptions(value, 'ox.conversation.start'); return __nativeConversationStart(options, String(purpose)); },
        send: value => { const options = __oxOptions(value, 'ox.conversation.send'); return __nativeConversationSend(String(options.id), String(options.text), String(options.purpose)); },
        wait: value => { const options = __oxOptions(value, 'ox.conversation.wait'); return __nativeConversationWait(String(options.id), options.timeoutSeconds ?? null, String(options.purpose)); },
        read: value => { const options = __oxOptions(value, 'ox.conversation.read'); return __nativeConversationRead(String(options.id), options.after ?? null, String(options.purpose)); },
        stop: value => { const options = __oxOptions(value, 'ox.conversation.stop'); return __nativeConversationStop(String(options.id), String(options.purpose)); },
        children: value => { const options = __oxOptions(value, 'ox.conversation.children'); return __nativeConversationChildren(String(options.purpose)); }
        """
    )

    private static let string = JSONValue.object(["type": .string("string")])
    private static let uuid = JSONValue.object(["type": .string("string"), "format": .string("uuid")])
    private static let childFields: [String: JSONValue] = [
        "id": string,
        "title": string,
        "state": enumeration(["running", "needsUser", "idle", "stopped", "failed"]),
        "blocked": enumeration(["approval", "reply", "login", "verification", "payment"]),
        "error": string,
        "updatedAt": string,
    ]
    private static let child = childWith([:])

    private static func childWith(_ extra: [String: JSONValue], required: [String] = []) -> JSONValue {
        object(childFields.merging(extra) { $1 }, required: ["id", "title", "state", "updatedAt"] + required)
    }

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
        "thinkingLevel": nullable(boundedString(maximum: 100, description: "Supported thinking level; null selects medium when supported, otherwise the model's lowest level. Omission preserves it for the same model.")),
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

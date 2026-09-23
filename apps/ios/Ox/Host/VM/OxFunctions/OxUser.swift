import Foundation
import JavaScriptCore

nonisolated enum OxUser {
    static let function = OxFunction(
        namespace: "user",
        schema: {
            [
                (
                    "ox.user.follow",
                    .object([
                        "description": .string("Show up to two likely next intents scoped to the current conversation above the empty composer without waiting for a response: `await ox.user.follow({ intents, purpose })`. Use `send` for a complete user message, or `actions` and `skills` for the built-in input forms. A send intent fills the composer for the user to review and send when tapped; form intents place a draft in the composer after the user supplies details."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "intents": .object([
                                    "type": .string("array"),
                                    "maxItems": .int(2),
                                    "items": .object([
                                        "type": .string("object"),
                                        "properties": .object([
                                            "kind": .object([
                                                "type": .string("string"),
                                                "enum": .array(["send", "actions", "skills"].map(JSONValue.string)),
                                            ]),
                                            "label": .object(["type": .string("string"), "maxLength": .int(80)]),
                                            "message": .object(["type": .string("string"), "maxLength": .int(1_000)]),
                                        ]),
                                        "required": .array([.string("kind")]),
                                        "additionalProperties": .bool(false),
                                    ]),
                                ]),
                            ]),
                            "required": .array([.string("intents")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("null")]),
                    ])
                ),
                (
                    "ox.user.reportProgress",
                    .object([
                        "description": .string("Post a concise progress update in the chat without ending the run: `await ox.user.reportProgress({ message, purpose })`. Use it during longer multi-step work; later reasoning and actions continue below the update."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "message": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(2_000),
                                ]),
                            ]),
                            "required": .array([.string("message")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("null")]),
                    ])
                ),
                (
                    "ox.user.choose",
                    .object([
                        "description": .string("Ask the user to pick one of 2-4 short labels or provide a short custom answer, then wait for their response: `await ox.user.choose({ body, options, purpose })`. Returns the chosen label or custom answer verbatim."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "body": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(2_000),
                                ]),
                                "options": .object([
                                    "type": .string("array"),
                                    "items": .object([
                                        "type": .string("string"),
                                        "minLength": .int(1),
                                        "maxLength": .int(80),
                                    ]),
                                    "minItems": .int(2),
                                    "maxItems": .int(4),
                                    "uniqueItems": .bool(true),
                                ]),
                            ]),
                            "required": .array([.string("body"), .string("options")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("string")]),
                    ])
                ),
            ]
        },
        installNatives: { context, env in
            let follow: @convention(block) (JSValue, String) -> JSValue = { intents, purpose in
                env.call { try await $0.followUser(intents: jsValueToJSON(intents) ?? .null, purpose: purpose) }
            }
            let reportProgress: @convention(block) (String, String) -> JSValue = { message, purpose in
                env.call { try await $0.reportProgress(message: message, purpose: purpose) }
            }
            let choose: @convention(block) (String, JSValue, String) -> JSValue = { body, options, purpose in
                let labels = jsValueToJSON(options)?.arrayValue?.compactMap(\.stringValue) ?? []
                return env.call(suspendingTimeout: true) { try await $0.chooseUser(body: body, options: labels, purpose: purpose) }
            }
            context.setObject(follow as AnyObject, forKeyedSubscript: "__nativeUserFollow" as NSString)
            context.setObject(reportProgress as AnyObject, forKeyedSubscript: "__nativeUserReportProgress" as NSString)
            context.setObject(choose as AnyObject, forKeyedSubscript: "__nativeUserChoose" as NSString)
        },
        jsFragment: """
          follow: (value) => { const options = __oxOptions(value, 'ox.user.follow'); return __nativeUserFollow(options.intents, String(options.purpose)); },
          choose: (value) => { const options = __oxOptions(value, 'ox.user.choose'); return __nativeUserChoose(String(options.body), options.options, String(options.purpose)); },
          reportProgress: (value) => { const options = __oxOptions(value, 'ox.user.reportProgress'); return __nativeUserReportProgress(String(options.message), String(options.purpose)); }
        """
    )
}

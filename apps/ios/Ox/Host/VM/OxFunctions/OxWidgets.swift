import Foundation
import JavaScriptCore

nonisolated enum OxWidgets {
    static let function = OxFunction(
        namespace: "widget",
        schema: {
            [
                (
                    "ox.widget.shoveler",
                    .object([
                        "description": .string("Display one horizontal strip of cards in the chat. A card with an `artifact` filename opens that artifact; other cards are read-only: `await ox.widget.shoveler({ cards, purpose })`."),
                        "inputSchema": object([
                            "cards": .object([
                                "type": .string("array"),
                                "items": card,
                                "minItems": .int(1),
                                "maxItems": .int(20),
                            ]),
                            "purpose": string(minLength: 1, maxLength: 80),
                        ], required: ["cards", "purpose"]),
                        "outputSchema": .object(["type": .string("null")]),
                    ])
                ),
                (
                    "ox.widget.video",
                    .object([
                        "description": .string("Display one inline video player in the chat: `await ox.widget.video({ video, purpose })`. `video` may be a public HTTPS URL or an existing video artifact filename."),
                        "inputSchema": object([
                            "video": string(minLength: 1, maxLength: 2_000),
                            "purpose": string(minLength: 1, maxLength: 80),
                        ], required: ["video", "purpose"]),
                        "outputSchema": .object(["type": .string("null")]),
                    ])
                ),
            ]
        },
        installNatives: { context, env in
            let shoveler: @convention(block) (JSValue, JSValue) -> JSValue = { value, purpose in
                env.call {
                    try await $0.presentShoveler(
                        value: jsValueToJSON(value),
                        purpose: purpose.toString()!
                    )
                }
            }
            context.setObject(shoveler as AnyObject, forKeyedSubscript: "__nativeWidgetShoveler" as NSString)
            let video: @convention(block) (JSValue, JSValue) -> JSValue = { value, purpose in
                env.call {
                    try await $0.presentVideo(
                        value: jsValueToJSON(value),
                        purpose: purpose.toString()!
                    )
                }
            }
            context.setObject(video as AnyObject, forKeyedSubscript: "__nativeWidgetVideo" as NSString)
        },
        jsFragment: """
          shoveler: (value) => { const options = __oxOptions(value, 'ox.widget.shoveler'); return __nativeWidgetShoveler({ cards: options.cards }, String(options.purpose)); },
          video: (value) => { const options = __oxOptions(value, 'ox.widget.video'); return __nativeWidgetVideo({ video: options.video }, String(options.purpose)); }
        """
    )

    private static let card = object([
        "image": string(maxLength: 2_000),
        "title": string(minLength: 1, maxLength: 120),
        "description": string(maxLength: 500),
        "badge": string(maxLength: 40),
        "artifact": string(maxLength: 255),
    ])

    private static func string(minLength: Int? = nil, maxLength: Int) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "maxLength": .int(maxLength)]
        if let minLength { schema["minLength"] = .int(minLength) }
        return .object(schema)
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

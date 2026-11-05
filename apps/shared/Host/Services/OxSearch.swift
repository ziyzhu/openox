import Foundation
import JavaScriptCore

nonisolated enum OxSearch {
    static let resultSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "service": .object(["type": .string("string")]),
            "items": .object([
                "type": .string("array"),
                "maxItems": .int(50),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string"), "minLength": .int(1)]),
                        "url": .object(["type": .array([.string("string"), .string("null")])]),
                        "snippet": .object(["type": .array([.string("string"), .string("null")])]),
                        "id": .object(["type": .string("string")]),
                        "data": .object(["type": .string("object")]),
                    ]),
                    "required": .array(["title", "url", "snippet"].map(JSONValue.string)),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "nextCursor": .object(["type": .array([.string("string"), .string("null")])]),
            "scope": .object(["type": .string("string"), "minLength": .int(1)]),
            "coverage": .object(["type": .string("string"), "enum": .array(["complete", "partial", "unknown"].map(JSONValue.string))]),
        ]),
        "required": .array(["service", "items", "nextCursor", "scope", "coverage"].map(JSONValue.string)),
        "additionalProperties": .bool(false),
    ])

    static let mergedResultSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "title": .object(["type": .string("string")]),
            "url": .object(["type": .array([.string("string"), .string("null")])]),
            "snippet": .object(["type": .array([.string("string"), .string("null")])]),
            "score": .object(["type": .string("number"), "minimum": .int(0), "description": .string("Reciprocal rank fusion retrieval score, not factual confidence.")]),
            "sources": .object([
                "type": .string("array"), "minItems": .int(1),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "service": .object(["type": .string("string")]),
                        "rank": .object(["type": .string("integer"), "minimum": .int(1)]),
                        "title": .object(["type": .string("string")]),
                        "url": .object(["type": .array([.string("string"), .string("null")])]),
                        "snippet": .object(["type": .array([.string("string"), .string("null")])]),
                    ]),
                    "required": .array(["service", "rank", "title", "url", "snippet"].map(JSONValue.string)),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array(["title", "url", "snippet", "score", "sources"].map(JSONValue.string)),
        "additionalProperties": .bool(false),
    ])

    static let function = OxFunction(
        namespace: "web",
        schema: {
            [("ox.web.search", .object([
                "description": .string(ModelGuidance.text("ox.web.search")),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(1000)]),
                        "domains": .object([
                            "type": .string("array"), "minItems": .int(1), "maxItems": .int(6), "uniqueItems": .bool(true),
                            "items": .object(["type": .string("string"), "pattern": .string("^[a-z0-9.-]+$")]),
                        ]),
                        "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(50), "default": .int(10)]),
                        "cursors": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string"), "minLength": .int(1)])]),
                        "sessions": .object(["type": .string("object"), "additionalProperties": WebSessionContract.sessionSchema]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                "outputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "results": .object(["type": .string("array"), "items": resultSchema]),
                        "mergedResults": .object(["type": .string("array"), "items": mergedResultSchema]),
                        "errors": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object(Dictionary(uniqueKeysWithValues: ["service", "code", "message"].map { ($0, JSONValue.object(["type": .string("string")])) })),
                                "required": .array(["service", "code", "message"].map(JSONValue.string)),
                                "additionalProperties": .bool(false),
                            ]),
                        ]),
                    ]),
                    "required": .array(["query", "results", "errors"].map(JSONValue.string)),
                    "additionalProperties": .bool(false),
                ]),
            ]))]
        },
        installNatives: { context, environment in
            let search: @convention(block) (JSValue) -> JSValue = { value in
                let arguments = jsValueToJSON(value) ?? .object([:])
                let purpose = arguments.objectValue?["purpose"]?.stringValue ?? ""
                return environment.call(suspendingTimeout: true) {
                    try await $0.searchWeb(arguments: arguments, purpose: purpose)
                }
            }
            context.setObject(search as AnyObject, forKeyedSubscript: "__nativeSearch" as NSString)
        },
        jsFragment: #"""
          search: (value) => __nativeSearch(__oxOptions(value, 'ox.web.search'))
        """#
    )
}

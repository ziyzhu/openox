import Foundation
import JavaScriptCore

nonisolated enum OxConversations {
    static let function = OxFunction(
        namespace: "conversation",
        schema: {
            [("ox.conversation.start", .object([
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
            ])), ("ox.conversation.delete", .object([
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
            ]))]
        },
        installNatives: { context, environment in
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
        start: value => { const options = __oxOptions(value, 'ox.conversation.start'); return __nativeConversationStart(String(options.prompt), String(options.title ?? ''), String(options.purpose)); },
        delete: value => { const options = __oxOptions(value, 'ox.conversation.delete'); return __nativeConversationDelete(String(options.id), String(options.purpose)); }
        """
    )
}

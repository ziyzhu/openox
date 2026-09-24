import Foundation
import JavaScriptCore

nonisolated enum OxChats {
    static let function = OxFunction(
        namespace: "chat",
        schema: {
            [("ox.chat.delete", .object([
                "description": .string("Permanently delete another chat in the active Profile: `await ox.chat.delete({ id, purpose })`. Find chat IDs with ox.fs.list at chats/. Always requires user approval, even with Allow policies. Cannot delete the calling chat. Deletes its transcript and context; Profile artifacts remain available."),
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
            let delete: @convention(block) (String, String) -> JSValue = { id, purpose in
                environment.call(suspendingTimeout: true) { try await $0.deleteChat(id: id, purpose: purpose) }
            }
            context.setObject(delete, forKeyedSubscript: "__nativeChatDelete" as NSString)
        },
        jsFragment: """
        delete: value => { const options = __oxOptions(value, 'ox.chat.delete'); return __nativeChatDelete(String(options.id), String(options.purpose)); }
        """
    )
}

import Foundation
import JavaScriptCore

nonisolated enum OxChats {
    static let function = OxFunction(
        namespace: "chat",
        schema: {
            [("ox.chat.start", .object([
                "description": .string("Start an independent chat in the active Profile: `await ox.chat.start({ prompt, title?, purpose })`. Returns its ID without waiting for the response or changing the selected chat. Uses the default model and a fresh context; include all task instructions in prompt. Read its metadata and transcript with ox.fs at `chats/<id>/{chat.json,turns.jsonl}`. Loaded chats expose current snapshots, including running/completed/failed/cancelled turn outcomes and pending prompts. A user-only transcript means work has not begun. The new chat uses normal Action policies and may need user attention. Temporary chats cannot start persisted chats."),
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
            ])), ("ox.chat.delete", .object([
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
            let start: @convention(block) (String, String, String) -> JSValue = { prompt, title, purpose in
                environment.call(suspendingTimeout: true) { try await $0.startChat(prompt: prompt, title: title, purpose: purpose) }
            }
            context.setObject(start, forKeyedSubscript: "__nativeChatStart" as NSString)
            let delete: @convention(block) (String, String) -> JSValue = { id, purpose in
                environment.call(suspendingTimeout: true) { try await $0.deleteChat(id: id, purpose: purpose) }
            }
            context.setObject(delete, forKeyedSubscript: "__nativeChatDelete" as NSString)
        },
        jsFragment: """
        start: value => { const options = __oxOptions(value, 'ox.chat.start'); return __nativeChatStart(String(options.prompt), String(options.title ?? ''), String(options.purpose)); },
        delete: value => { const options = __oxOptions(value, 'ox.chat.delete'); return __nativeChatDelete(String(options.id), String(options.purpose)); }
        """
    )
}

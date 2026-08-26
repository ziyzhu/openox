import Foundation
import JavaScriptCore

nonisolated enum OxOutput {
    static let function = OxFunction(
        namespace: "output",
        schema: {
            [("ox.output.read", .object([
                "description": .string("Read the complete text of a captured JavaScript output into JavaScript: `await ox.output.read({ id, purpose })`. Use an id from an output-truncation notice. Filter or slice the returned string before printing. References are private to this loaded chat, including temporary chats, and expire when it is unloaded; they are not saved artifacts."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                ]),
                "outputSchema": .object(["type": .string("string")]),
            ]))]
        },
        installNatives: { context, env in
            let read: @convention(block) (String, String) -> JSValue = { id, purpose in
                env.call { try await $0.readJavaScriptOutput(id: id, purpose: purpose) }
            }
            context.setObject(read as AnyObject, forKeyedSubscript: "__nativeOutputRead" as NSString)
        },
        jsFragment: """
          read: (value) => { const options = __oxOptions(value, 'ox.output.read'); return __nativeOutputRead(String(options.id), String(options.purpose)); }
        """
    )
}

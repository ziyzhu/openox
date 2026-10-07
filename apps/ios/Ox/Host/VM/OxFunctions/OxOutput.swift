import Foundation
import JavaScriptCore

nonisolated enum OxOutput {
    static let function = OxFunction(
        namespace: "output",
        schema: {
            [("ox.output.read", .object([
                "description": .string("Read the complete text of a captured JavaScript output into JavaScript: `await ox.output.read({ purpose, id })`. Use an id from an output-truncation notice or an archived invocation result. Filter or slice the returned string before printing. Ordinary output ids expire when this chat is unloaded. `payload:<sha256>:<offset>:<length>` ids read bounded UTF-8 JSON ranges from immutable files committed in this chat's durable Profile; saved Profile payloads survive reopening. Use JSON.parse to recover the archived result. Each payload read is limited to 32 MiB; larger ranges must be read in smaller pieces."),
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

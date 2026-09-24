import Foundation

extension Chat {
    func secretOperation(name: String, arguments: JSONValue, purpose: String) async throws -> JSONValue? {
        guard let fields = arguments.objectValue else { throw RuntimeError.bridge("Invalid Secret arguments") }
        let operation = "ox.secret.\(name)"
        return try await tracked(operation, arguments, purpose: purpose) {
            switch name {
            case "list":
                return .array(try Secret.entries().map { entry in
                    let available = try Credentials.secretChecked(for: "secret:\(entry.key)") != nil
                    return .object(["key": .string(entry.key), "available": .bool(available)])
                })
            case "add":
                guard let key = fields["key"]?.stringValue else { throw RuntimeError.bridge("Secret key is required") }
                try Secret.validateKey(key)
                guard !key.hasPrefix("ox.") else { throw RuntimeError.bridge("Secret key is reserved") }
                let status = await awaitPrompt(prompt: "Save a secret: \(key)",
                                               options: ["Saved", "Cancelled"], secretKey: key)
                return .object(["key": .string(key), "status": .string(status == "Saved" ? "saved" : "cancelled")])
            case "delete":
                guard let key = fields["key"]?.stringValue,
                      try Secret.entry(key: key) != nil else { throw RuntimeError.bridge("Secret entry was not found") }
                let answer = await awaitPrompt(prompt: "Delete secret \(key)? Connections using it will need to be set up again.",
                                                options: ["Delete", "Cancel"])
                if answer == "Delete" {
                    try Secret.delete(key: key)
                    return .object(["key": .string(key), "status": .string("deleted")])
                }
                return .object(["key": .string(key), "status": .string("cancelled")])
            default: throw RuntimeError.bridge("Unknown Secret operation")
            }
        }
    }
}

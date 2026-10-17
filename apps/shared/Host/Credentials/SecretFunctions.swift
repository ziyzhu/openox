import Foundation

extension Conversation {
    func secretOperation(name: String, arguments: JSONValue, purpose: String) async throws -> JSONValue? {
        guard let fields = arguments.objectValue else { throw RuntimeError.bridge("Invalid Secret arguments") }
        let operation = "ox.secret.\(name)"
        return try await tracked(operation, arguments, purpose: purpose) {
            switch name {
            case "list":
                return .array(try Secret.userManagedEntries().map { entry in
                    let value = try Credentials.secretChecked(for: "secret:\(entry.key)")
                    let fieldNames: [String]
                    if let value {
                        guard let fields = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: String] else {
                            throw RuntimeError.bridge("Secret metadata is unavailable")
                        }
                        fieldNames = fields.keys.sorted()
                    } else {
                        fieldNames = []
                    }
                    return .object([
                        "key": .string(entry.key),
                        "displayName": .string(entry.displayName),
                        "fields": .array(fieldNames.map(JSONValue.string)),
                        "available": .bool(value != nil),
                    ])
                })
            case "add":
                guard let key = fields["key"]?.stringValue else { throw RuntimeError.bridge("Secret key is required") }
                try Secret.validateKey(key)
                guard !key.hasPrefix("ox.") else { throw RuntimeError.bridge("Secret key is reserved") }
                if let presenter = presentations.secretEntry {
                    let saved = try await presenter(key)
                    return .object(["key": .string(key), "status": .string(saved ? "saved" : "cancelled")])
                }
                let status = await awaitPrompt(prompt: "Save a secret: \(key)",
                                               options: ["Saved", "Cancelled"], secretEntry: SecretEntryRequest(key: key))
                return .object(["key": .string(key), "status": .string(status == "Saved" ? "saved" : "cancelled")])
            case "delete":
                guard let key = fields["key"]?.stringValue,
                      try Secret.userManagedEntries().contains(where: { $0.key == key }) else { throw RuntimeError.bridge("Secret entry was not found") }
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

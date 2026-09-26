import Foundation

enum RuntimeError: Error {
    case bridge(String)
}

struct SecretEntry {
    let key: String
    let displayName: String
}

enum Secret {
    static var storedEntries: [SecretEntry] = []
    static func entries() throws -> [SecretEntry] { storedEntries }
    static func entry(key: String) throws -> SecretEntry? { storedEntries.first { $0.key == key } }
    static func validateKey(_ key: String) throws { fatalError("Unexpected write path") }
    static func delete(key: String) throws { fatalError("Unexpected write path") }
}

enum Credentials {
    static var values: [String: String] = [:]
    static var unavailable = false
    static func secretChecked(for key: String) throws -> String? {
        if unavailable { throw RuntimeError.bridge("Keychain unavailable") }
        return values[key]
    }
}

struct SecretEntryRequest {
    let key: String
}

struct Chat {
    func tracked<T>(_ action: String, _ args: JSONValue, purpose: String, _ body: () async throws -> T) async throws -> T {
        try await body()
    }

    func awaitPrompt(prompt: String, options: [String], secretEntry: SecretEntryRequest? = nil) async -> String {
        fatalError("Metadata reads must not prompt")
    }
}

@main
struct SecretMetadataTests {
    static func list() async throws -> JSONValue? {
        try await Chat().secretOperation(name: "list", arguments: .object([:]), purpose: "Inspect secret metadata")
    }

    static func main() async throws {
        let empty = try await list()
        precondition(empty == .array([]))
        Secret.storedEntries = [
            SecretEntry(key: "weather-api", displayName: "Weather API"),
            SecretEntry(key: "offline", displayName: "Offline account"),
        ]
        Credentials.values = ["secret:weather-api": #"{"token":"synthetic-private-token","accountId":"synthetic-private-account","apiKey":"synthetic-private-key"}"#]
        let metadata = try await list()
        precondition(metadata == .array([
            .object([
                "key": .string("weather-api"), "displayName": .string("Weather API"),
                "fields": .array([.string("accountId"), .string("apiKey"), .string("token")]),
                "available": .bool(true),
            ]),
            .object([
                "key": .string("offline"), "displayName": .string("Offline account"),
                "fields": .array([]), "available": .bool(false),
            ]),
        ]))
        let encoded = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        precondition(!encoded.contains("synthetic-private"))

        for invalid in ["synthetic-private-malformed", #"["synthetic-private-array"]"#, #"{"token":{"nested":"synthetic-private-nested"}}"#] {
            Credentials.values["secret:weather-api"] = invalid
            do {
                _ = try await list()
                preconditionFailure("Invalid secrets must fail closed")
            } catch RuntimeError.bridge(let message) {
                precondition(message == "Secret metadata is unavailable")
            }
        }

        Credentials.unavailable = true
        do {
            _ = try await list()
            preconditionFailure("Keychain failures must propagate")
        } catch RuntimeError.bridge(let message) {
            precondition(message == "Keychain unavailable")
        }
        print("PASS metadata allowlist, sorted fields, absent values, sanitized errors, and Keychain failure")
    }
}

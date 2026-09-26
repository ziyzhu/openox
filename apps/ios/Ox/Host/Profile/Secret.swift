import CryptoKit
import Foundation
import Security
import Synchronization

nonisolated enum SecretConsumerKind: String, Codable, Sendable {
    case provider
    case apiService
    case repositoryPublication
}

nonisolated enum SecretEntryOrigin: Codable, Sendable {
    case named
    case generatedFor(SecretConsumerKind, String)
}

nonisolated enum SecretUsePolicy: String, Codable, Sendable {
    case reusable
    case publicationOnly
}

nonisolated struct SecretEntry: Codable, Sendable {
    let key: String
    var displayName: String
    let origin: SecretEntryOrigin
    let usePolicy: SecretUsePolicy
}

nonisolated struct SecretBinding: Codable, Sendable {
    let consumerKind: SecretConsumerKind
    let consumerID: String
    let secretKey: String
    let destination: String
    let configurationFingerprint: String
    let requiredFields: [String]
}

nonisolated struct SecretIndex: Codable, Sendable {
    var version = 1
    var entries: [SecretEntry] = []
    var bindings: [SecretBinding] = []

    func validate() throws {
        guard version == 1,
              Set(entries.map(\.key)).count == entries.count,
              Set(bindings.map { "\($0.consumerKind.rawValue):\($0.consumerID)" }).count == bindings.count else {
            throw RuntimeError.bridge("Secret metadata is incompatible")
        }
        let keys = Set(entries.map(\.key))
        for entry in entries {
            try Secret.validateKey(entry.key)
            try Secret.validateDisplayName(entry.displayName)
        }
        guard bindings.allSatisfy({ keys.contains($0.secretKey) && !$0.consumerID.isEmpty && !$0.destination.isEmpty }) else {
            throw RuntimeError.bridge("Secret binding metadata is invalid")
        }
    }
}

nonisolated enum Secret {
    static let indexKey = "secret.index"
    private static let publicationKey = "ox.repository.github"
    private static let publicationID = "openox"
    private static let publicationDestination = "https://api.github.com"
    private static let lock = Mutex(())

    static func entries() throws -> [SecretEntry] {
        try index().entries
    }

    static func entry(key: String) throws -> SecretEntry? {
        try index().entries.first { $0.key == key }
    }

    static func binding(kind: SecretConsumerKind, id: String) throws -> SecretBinding? {
        try index().bindings.first { $0.consumerKind == kind && $0.consumerID == id }
    }

    static func bindings(for key: String) throws -> [SecretBinding] {
        try index().bindings.filter { $0.secretKey == key }
    }

    static func value(key: String) throws -> String? {
        try validateKey(key)
        guard try entry(key: key) != nil else { return nil }
        return try Credentials.secretChecked(for: "secret:\(key)")
    }

    static func set(key: String, displayName: String, value: String, origin: SecretEntryOrigin = .named,
                    usePolicy: SecretUsePolicy = .reusable) throws {
        try validateKey(key)
        if key.hasPrefix("ox."), case .named = origin {
            throw RuntimeError.bridge("Secret key is reserved")
        }
        try validateDisplayName(displayName)
        let fields = try validateJSON(value)
        try lock.withLock { _ in
            var current = try index()
            if let position = current.entries.firstIndex(where: { $0.key == key }) {
                guard current.entries[position].usePolicy == usePolicy else {
                    throw RuntimeError.bridge("Secret entry policy cannot be changed")
                }
                current.entries[position].displayName = displayName
                for binding in current.bindings where binding.secretKey == key {
                    guard binding.requiredFields.allSatisfy({ fields[$0] is String }) else {
                        throw RuntimeError.bridge("Secret value is missing fields required by a consumer")
                    }
                }
            } else {
                current.entries.append(SecretEntry(key: key, displayName: displayName,
                                                  origin: origin, usePolicy: usePolicy))
            }
            try Credentials.setSecretChecked(value, for: "secret:\(key)",
                                             accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            guard try Credentials.secretChecked(for: "secret:\(key)") == value else {
                throw RuntimeError.bridge("Secret entry could not be verified")
            }
            try save(current)
        }
    }

    static func delete(key: String) throws {
        try lock.withLock { _ in
            var current = try index()
            try Credentials.deleteSecretChecked(for: "secret:\(key)")
            current.bindings.removeAll { $0.secretKey == key }
            current.entries.removeAll { $0.key == key }
            try save(current)
        }
    }

    static func bind(_ binding: SecretBinding) throws {
        try lock.withLock { _ in
            var current = try index()
            guard let entry = current.entries.first(where: { $0.key == binding.secretKey }),
                  try Credentials.secretChecked(for: "secret:\(binding.secretKey)") != nil else {
                throw RuntimeError.bridge("Secret entry is unavailable")
            }
            guard entry.usePolicy == .reusable || binding.consumerKind == .repositoryPublication else {
                throw RuntimeError.bridge("Secret entry cannot be assigned to this consumer")
            }
            let previous = current.bindings.first {
                $0.consumerKind == binding.consumerKind && $0.consumerID == binding.consumerID
            }
            current.bindings.removeAll {
                $0.consumerKind == binding.consumerKind && $0.consumerID == binding.consumerID
            }
            current.bindings.append(binding)
            try save(current)
            if let previous, previous.secretKey != binding.secretKey,
               let oldEntry = current.entries.first(where: { $0.key == previous.secretKey }),
               case .generatedFor(binding.consumerKind, binding.consumerID) = oldEntry.origin,
               !current.bindings.contains(where: { $0.secretKey == oldEntry.key }) {
                try Credentials.deleteSecretChecked(for: "secret:\(oldEntry.key)")
                current.entries.removeAll { $0.key == oldEntry.key }
                try save(current)
            }
        }
    }

    static func unbind(_ kind: SecretConsumerKind, id: String) throws {
        try lock.withLock { _ in
            var current = try index()
            let removed = current.bindings.filter { $0.consumerKind == kind && $0.consumerID == id }
            current.bindings.removeAll { $0.consumerKind == kind && $0.consumerID == id }
            try save(current)
            for binding in removed {
                guard let entry = current.entries.first(where: { $0.key == binding.secretKey }),
                      case .generatedFor(kind, id) = entry.origin,
                      !current.bindings.contains(where: { $0.secretKey == entry.key }) else { continue }
                try Credentials.deleteSecretChecked(for: "secret:\(entry.key)")
                current.entries.removeAll { $0.key == entry.key }
                try save(current)
            }
        }
    }

    static func providerKey(for credentialID: String) -> String? {
        guard let current = try? index(),
              let binding = current.bindings.first(where: {
                  $0.consumerKind == .provider && $0.consumerID == credentialID
              }) else { return nil }
        if credentialID.hasPrefix("custom:") {
            guard let data = UserDefaults.standard.data(forKey: ProviderRegistry.catalogKey),
                  let catalog = try? JSONDecoder().decode(ProviderCatalog.self, from: data),
                  let definition = catalog.providers.first(where: { $0.id == credentialID }),
                  binding.configurationFingerprint == providerFingerprint(definition),
                  binding.destination == definition.url.absoluteString else { return nil }
        }
        guard
              let value = try? Credentials.secretChecked(for: "secret:\(binding.secretKey)"),
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let apiKey = object["apiKey"] as? String, !apiKey.isEmpty else { return nil }
        return apiKey
    }

    static func saveProviderKey(_ value: String, definition: ProviderDefinition) throws {
        let credential = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw RuntimeError.bridge("A credential is required") }
        let digest = SHA256.hash(data: Data(definition.credentialID.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        let key = try generatedKey(base: "ox.provider.\(digest)", kind: .provider,
                                   id: definition.credentialID)
        let data = try JSONSerialization.data(withJSONObject: ["apiKey": credential], options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let displayName = definition.name.hasSuffix(" API")
            ? "\(definition.name) key"
            : "\(definition.name.replacingOccurrences(of: " API ·", with: " ·")) API key"
        try set(key: key, displayName: displayName, value: json,
                origin: .generatedFor(.provider, definition.credentialID))
        try bindProvider(key: key, definition: definition)
    }

    static func bindProvider(key: String, definition: ProviderDefinition) throws {
        guard let value = try value(key: key),
              let data = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty else {
            throw RuntimeError.bridge("Secret entry must contain a nonempty apiKey")
        }
        let binding = SecretBinding(consumerKind: .provider, consumerID: definition.credentialID,
                                   secretKey: key, destination: definition.url.absoluteString,
                                   configurationFingerprint: providerFingerprint(definition),
                                   requiredFields: ["apiKey"])
        try bind(binding)
    }

    static func apiServiceCredential(id: String, fingerprint: String, auth: APIServiceAuth) throws -> (String, String?)? {
        guard let binding = try binding(kind: .apiService, id: id),
              binding.configurationFingerprint == fingerprint,
              let value = try value(key: binding.secretKey),
              let data = value.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch auth {
        case .apiKey:
            guard let secret = fields["apiKey"] as? String, !secret.isEmpty else { return nil }
            return (secret, nil)
        case .bearer:
            guard let secret = fields["token"] as? String, !secret.isEmpty else { return nil }
            return (secret, nil)
        case .basic:
            guard let secret = fields["password"] as? String,
                  let username = fields["username"] as? String else { return nil }
            return (secret, username)
        case .none, .oauth: return nil
        }
    }

    static func saveAPIServiceCredential(_ credential: APIServiceCredential, id: String,
                                         displayName: String, destination: String,
                                         auth: APIServiceAuth) throws {
        let fields: [String: String]
        switch auth {
        case .apiKey: fields = ["apiKey": credential.secret]
        case .bearer: fields = ["token": credential.secret]
        case .basic: fields = ["username": credential.username ?? "", "password": credential.secret]
        case .none, .oauth: throw RuntimeError.bridge("Managed OAuth is not a secret entry")
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let key = try generatedKey(base: "ox.api-service.\(id.prefix(24))", kind: .apiService, id: id)
        try set(key: key, displayName: displayName, value: String(decoding: data, as: UTF8.self),
                origin: .generatedFor(.apiService, id))
        try bind(SecretBinding(consumerKind: .apiService, consumerID: id, secretKey: key,
                              destination: destination, configurationFingerprint: credential.binding,
                              requiredFields: fields.keys.sorted()))
    }

    static func providerFingerprint(_ definition: ProviderDefinition) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let authentication = (try? encoder.encode(definition.auth)) ?? Data()
        let input = Data(definition.id.utf8) + Data(definition.url.absoluteString.utf8) + authentication
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    static func publicationToken() -> String? {
        guard let binding = try? binding(kind: .repositoryPublication, id: publicationID),
              binding.secretKey == publicationKey,
              binding.destination == publicationDestination,
              binding.configurationFingerprint == publicationID,
              let entry = try? entry(key: publicationKey), entry.usePolicy == .publicationOnly,
              let value = try? value(key: publicationKey),
              let data = value.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return fields["token"] as? String
    }

    static func savePublicationToken(_ token: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["token": token], options: [.sortedKeys])
        try set(key: publicationKey, displayName: "OpenOx GitHub publication token",
                value: String(decoding: data, as: UTF8.self),
                origin: .generatedFor(.repositoryPublication, publicationID), usePolicy: .publicationOnly)
        try bind(SecretBinding(consumerKind: .repositoryPublication, consumerID: publicationID,
                              secretKey: publicationKey, destination: publicationDestination,
                              configurationFingerprint: publicationID, requiredFields: ["token"]))
    }

    static func clearPublicationToken() throws {
        try unbind(.repositoryPublication, id: publicationID)
    }

    static func validateKey(_ key: String) throws {
        guard key.utf8.count <= 128,
              key.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw RuntimeError.bridge("Invalid secret key")
        }
    }

    static func validateDisplayName(_ name: String) throws {
        guard !name.isEmpty, name.unicodeScalars.count <= 80,
              name == name.precomposedStringWithCanonicalMapping else {
            throw RuntimeError.bridge("Invalid secret display name")
        }
    }

    private static func validateJSON(_ value: String) throws -> [String: Any] {
        guard value.utf8.count <= 16_384, let data = value.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              !fields.isEmpty,
              fields.allSatisfy({ !$0.key.isEmpty && $0.value is String }) else {
            throw RuntimeError.bridge("Secret value must be a flat JSON object of string fields")
        }
        var validator = SecretJSONValidator(bytes: Array(data))
        try validator.validate()
        return fields
    }

    private static func index() throws -> SecretIndex {
        guard let data = UserDefaults.standard.data(forKey: indexKey) else { return SecretIndex() }
        let current = try JSONDecoder().decode(SecretIndex.self, from: data)
        try current.validate()
        return current
    }

    private static func save(_ index: SecretIndex) throws {
        try index.validate()
        let data = try JSONEncoder().encode(index)
        UserDefaults.standard.set(data, forKey: indexKey)
        guard UserDefaults.standard.data(forKey: indexKey) == data else {
            throw RuntimeError.bridge("Secret metadata could not be saved")
        }
    }

    private static func generatedKey(base: String, kind: SecretConsumerKind, id: String) throws -> String {
        let current = try index()
        if let binding = current.bindings.first(where: { $0.consumerKind == kind && $0.consumerID == id }),
           let entry = current.entries.first(where: { $0.key == binding.secretKey }),
           case .generatedFor(kind, id) = entry.origin,
           current.bindings.filter({ $0.secretKey == entry.key }).count == 1 {
            return entry.key
        }
        guard current.entries.contains(where: { $0.key == base }) else { return base }
        return "\(base).\(UUID().uuidString.lowercased())"
    }
}

nonisolated private struct SecretJSONValidator {
    let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func validate() throws {
        skipWhitespace()
        guard take(123) else { throw RuntimeError.bridge("Secret value must be a JSON object") }
        try object(depth: 1)
        skipWhitespace()
        guard position == bytes.count else { throw RuntimeError.bridge("Secret JSON has trailing content") }
    }

    private mutating func object(depth: Int) throws {
        guard depth <= 8 else { throw RuntimeError.bridge("Secret JSON is too deeply nested") }
        skipWhitespace()
        if take(125) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let key = try string()
            guard keys.insert(key).inserted else { throw RuntimeError.bridge("Secret JSON has duplicate fields") }
            skipWhitespace()
            guard take(58) else { throw RuntimeError.bridge("Secret JSON is invalid") }
            try value(depth: depth)
            skipWhitespace()
            if take(125) { return }
            guard take(44) else { throw RuntimeError.bridge("Secret JSON is invalid") }
        }
    }

    private mutating func array(depth: Int) throws {
        guard depth <= 8 else { throw RuntimeError.bridge("Secret JSON is too deeply nested") }
        skipWhitespace()
        if take(93) { return }
        while true {
            try value(depth: depth)
            skipWhitespace()
            if take(93) { return }
            guard take(44) else { throw RuntimeError.bridge("Secret JSON is invalid") }
        }
    }

    private mutating func value(depth: Int) throws {
        skipWhitespace()
        guard position < bytes.count else { throw RuntimeError.bridge("Secret JSON is invalid") }
        if take(123) { try object(depth: depth + 1); return }
        if take(91) { try array(depth: depth + 1); return }
        if bytes[position] == 34 { _ = try string(); return }
        let start = position
        while position < bytes.count, ![44, 93, 125, 9, 10, 13, 32].contains(bytes[position]) {
            position += 1
        }
        guard position > start,
              (try? JSONSerialization.jsonObject(with: Data(bytes[start..<position]), options: .fragmentsAllowed)) != nil else {
            throw RuntimeError.bridge("Secret JSON is invalid")
        }
    }

    private mutating func string() throws -> String {
        guard take(34) else { throw RuntimeError.bridge("Secret JSON is invalid") }
        let start = position - 1
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == 92 {
                guard position < bytes.count else { break }
                position += 1
            } else if byte == 34 {
                let data = Data(bytes[start..<position])
                guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
                    throw RuntimeError.bridge("Secret JSON is invalid")
                }
                return value
            }
        }
        throw RuntimeError.bridge("Secret JSON is invalid")
    }

    private mutating func skipWhitespace() {
        while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }
}

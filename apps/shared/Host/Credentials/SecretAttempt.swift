import Foundation

nonisolated struct SecretUse: Equatable, Sendable {
    static let prefix = "secret-use:"

    let key: String
    let consumer: String

    init(key: String, consumer: String) {
        self.key = key
        self.consumer = consumer
    }

    init?(action: String) {
        guard action.hasPrefix(Self.prefix) else { return nil }
        let rest = action.dropFirst(Self.prefix.count)
        guard let separator = rest.firstIndex(of: "@") else { return nil }
        key = String(rest[..<separator])
        consumer = String(rest[rest.index(after: separator)...])
        guard !key.isEmpty, !consumer.isEmpty else { return nil }
    }

    var action: String { "\(Self.prefix)\(key)@\(consumer)" }

    var consumerNamespace: String {
        guard let separator = consumer.lastIndex(of: ":") else { return consumer }
        return String(consumer[..<separator])
    }

    func policy() -> ActionPolicy {
        guard let entry = try? Secret.entry(key: key), entry.type != nil, entry.usePolicy == .reusable else { return .block }
        let rules = entry.access ?? []
        return rules.first { $0.consumer == consumer }?.policy
            ?? rules.first { $0.consumer == consumerNamespace }?.policy
            ?? .ask
    }

    func allow() -> Bool {
        do {
            try Secret.setAccess(key: key, consumer: consumer, policy: .allow)
            return true
        } catch {
            Log.service.error("SecretUse.allow key=\(key) consumer=\(consumer) error=\(error.localizedDescription)")
            return false
        }
    }
}

nonisolated enum LoginStepEnd: String, Sendable {
    case running
    case finished
    case awaitingPerson
    case leftSite
    case stalled
}

nonisolated enum SecretAttemptError: LocalizedError {
    case invalidReference
    case notPassed
    case unavailable
    case notOwner
    case wrongOrigin
    case denied
    case approvalRequired

    var errorDescription: String? {
        switch self {
        case .invalidReference: "Secret reference is invalid; pass { $secret: key } from ox.service.inspect."
        case .notPassed: "This secret was not passed to this action."
        case .unavailable: "Secret unavailable."
        case .notOwner: "Only the service that owns this secret can retrieve it."
        case .wrongOrigin: "Secret retrieval is allowed only on the owning service's domain."
        case .denied: "The user did not allow this action to use the secret."
        case .approvalRequired: "Waiting for the user to allow this action to use the secret."
        }
    }
}

@MainActor
final class SecretAttempt {
    let id = UUID()
    let consumer: String
    let keys: Set<String>
    private let approve: (SecretUse, String) async -> Bool
    private var approved: Set<String> = []
    private(set) var awaitingApproval: Set<String> = []
    private(set) var denied = false
    private var released: Set<String> = []
    private(set) var retrievals = 0
    var stepEnd = LoginStepEnd.finished
    private var renderings: [ObjectIdentifier: () -> Void] = [:]
    private static var rejectedAt: [String: Date] = [:]
    private static let cooldown: TimeInterval = 600

    var isCoolingDown: Bool {
        keys.contains { Self.rejectedAt[$0].map { Date().timeIntervalSince($0) < Self.cooldown } ?? false }
    }

    func recordRejection() {
        for key in keys { Self.rejectedAt[key] = Date() }
        Log.service.info("SecretAttempt.rejected id=\(id.uuidString.prefix(8)) consumer=\(consumer) cooldown=\(Int(Self.cooldown))")
    }

    func recordSuccess() {
        for key in keys { Self.rejectedAt[key] = nil }
    }

    private static let live = NSHashTable<SecretAttempt>.weakObjects()

    init(consumer: String, keys: Set<String>, approve: @escaping (SecretUse, String) async -> Bool) {
        self.consumer = consumer
        self.keys = keys
        self.approve = approve
        Self.live.add(self)
    }

    var holdsValues: Bool { !released.isEmpty }

    func keepRendering(_ page: BrowserSession) {
        let id = ObjectIdentifier(page)
        guard renderings[id] == nil else { return }
        renderings[id] = HiddenPageHost.keep(page.page)
    }

    func releaseRendering() {
        let releases = renderings.values
        renderings.removeAll()
        releases.forEach { $0() }
    }

    var owners: Set<String> {
        Set(keys.compactMap { try? Secret.entry(key: $0)?.serviceID })
    }

    var accountIdentities: [String: String] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            (try? Secret.entry(key: key))?.accountIdentity.map { (key, $0) }
        })
    }

    var usernames: [String: String] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            (try? Secret.fields(key: key))?["username"].map { (key, $0.lowercased()) }
        })
    }

    static func redactLive(_ value: JSONValue) -> JSONValue {
        live.allObjects.reduce(value) { $1.redact($0) }
    }

    static func redactLive(_ text: String) -> String {
        live.allObjects.reduce(text) { $1.redact($0) }
    }

    static func prepare(_ args: JSONValue) throws -> (args: JSONValue, keys: Set<String>) {
        let references = SecretReference.collect(args)
        guard !references.isEmpty else { return (args, []) }
        var keys: Set<String> = []
        let annotated = try SecretReference.annotate(args) { reference in
            guard let entry = try Secret.entry(key: reference.key), let type = entry.type,
                  entry.usePolicy == .reusable, let owner = entry.serviceID else {
                throw SecretAttemptError.invalidReference
            }
            if let field = reference.field, !type.fields.contains(field) { throw SecretAttemptError.invalidReference }
            keys.insert(reference.key)
            return owner
        }
        return (annotated, keys)
    }

    func authorize() async -> Bool {
        for key in keys.sorted() where !approved.contains(key) {
            let use = SecretUse(key: key, consumer: consumer)
            switch use.policy() {
            case .block:
                Log.service.info("SecretAttempt.authorize id=\(id.uuidString.prefix(8)) key=\(key) consumer=\(consumer) policy=block")
                return false
            case .allow:
                approved.insert(key)
            case .ask:
                guard let entry = try? Secret.entry(key: key), await approve(use, entry.displayName) else {
                    Log.service.info("SecretAttempt.authorize id=\(id.uuidString.prefix(8)) key=\(key) consumer=\(consumer) answer=denied")
                    return false
                }
                approved.insert(key)
            }
        }
        return true
    }

    func authorizePending() async -> Bool {
        let pending = awaitingApproval.sorted()
        awaitingApproval.removeAll()
        for key in pending where !approved.contains(key) {
            guard let entry = try? Secret.entry(key: key),
                  await approve(SecretUse(key: key, consumer: consumer), entry.displayName) else {
                denied = true
                Log.service.info("SecretAttempt.authorize id=\(id.uuidString.prefix(8)) key=\(key) consumer=\(consumer) answer=denied")
                return false
            }
            approved.insert(key)
        }
        return true
    }

    func retrieve(_ value: JSONValue, caller namespace: String, host: String?) async throws -> JSONValue {
        guard let reference = SecretReference(value) else { throw SecretAttemptError.invalidReference }
        guard keys.contains(reference.key) else { throw SecretAttemptError.notPassed }
        guard let entry = try Secret.entry(key: reference.key), let type = entry.type, let owner = entry.serviceID else {
            throw SecretAttemptError.unavailable
        }
        guard owner == namespace else { throw SecretAttemptError.notOwner }
        if let host, !Self.host(host, isWithin: owner) { throw SecretAttemptError.wrongOrigin }
        switch SecretUse(key: reference.key, consumer: consumer).policy() {
        case .block:
            denied = true
            throw SecretAttemptError.denied
        case .allow:
            approved.insert(reference.key)
        case .ask where !approved.contains(reference.key):
            awaitingApproval.insert(reference.key)
            throw SecretAttemptError.approvalRequired
        case .ask:
            break
        }
        guard let fields = try Secret.fields(key: reference.key), Set(fields.keys) == Set(type.fields) else {
            throw SecretAttemptError.unavailable
        }
        released.formUnion(fields.values.filter { $0.count >= 4 })
        retrievals += 1
        Log.service.info("SecretAttempt.retrieve id=\(id.uuidString.prefix(8)) key=\(reference.key) consumer=\(consumer) owner=\(owner) field=\(reference.field ?? "all")")
        if let field = reference.field { return .string(fields[field] ?? "") }
        return .object(fields.mapValues(JSONValue.string))
    }

    func substitute(_ value: JSONValue, caller namespace: String) async throws -> JSONValue {
        if SecretReference(value) != nil { return try await retrieve(value, caller: namespace, host: nil) }
        switch value {
        case .array(let items):
            var result: [JSONValue] = []
            for item in items { result.append(try await substitute(item, caller: namespace)) }
            return .array(result)
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (name, item) in fields { result[name] = try await substitute(item, caller: namespace) }
            return .object(result)
        default:
            return value
        }
    }

    func redact(_ value: JSONValue) -> JSONValue {
        guard !released.isEmpty else { return value }
        switch value {
        case .string(let text): return .string(redact(text))
        case .array(let items): return .array(items.map(redact))
        case .object(let fields): return .object(fields.mapValues(redact))
        default: return value
        }
    }

    func redact(_ text: String) -> String {
        var result = text
        for secret in released {
            for form in Self.forms(of: secret) where result.contains(form) {
                result = result.replacingOccurrences(of: form, with: "[redacted]")
            }
        }
        return result
    }

    private static func forms(of secret: String) -> [String] {
        let data = Data(secret.utf8)
        return [
            secret,
            data.base64EncodedString(),
            data.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "=")),
            secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? secret,
        ]
    }

    static func host(_ host: String, isWithin owner: String) -> Bool {
        guard let separator = owner.firstIndex(of: ":") else { return false }
        let domain = owner[owner.index(after: separator)...].lowercased()
        let host = host.lowercased()
        return host == domain || host.hasSuffix(".\(domain)")
    }
}

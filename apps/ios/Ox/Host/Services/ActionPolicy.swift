import Foundation

nonisolated enum ActionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case allow
    case block

    var id: String { rawValue }
}

nonisolated struct ActionPolicyConfiguration: Codable, Equatable, Sendable {
    static let currentFormat = 2
    static let legacyFormat = 1

    let format: Int
    var defaultPolicy: ActionPolicy?
    var sources: [String: ActionPolicy]
    var actions: [String: ActionPolicy]

    init(
        format: Int = currentFormat,
        defaultPolicy: ActionPolicy? = nil,
        sources: [String: ActionPolicy] = [:],
        actions: [String: ActionPolicy] = [:]
    ) {
        self.format = format
        self.defaultPolicy = defaultPolicy
        self.sources = sources
        self.actions = actions
    }

    func policy(for action: String, default actionDefault: ActionPolicy) -> ActionPolicy {
        actions[action] ?? sources[Self.sourceID(for: action)] ?? defaultPolicy ?? actionDefault
    }

    static func sourceID(for action: String) -> String {
        let attachPrefix = "ox.service.attach:"
        if action.hasPrefix(attachPrefix) {
            return String(action.dropFirst(attachPrefix.count))
        }
        if action.hasPrefix("ox.fs.") { return "ios:files" }
        if action.hasPrefix("ox.") { return "ox" }
        guard let separator = action.lastIndex(of: ":") else { return "ox" }
        let namespace = String(action[..<separator])
        for prefix in ["web:", "api:", "mcp:"] where namespace.hasPrefix(prefix) {
            return String(namespace.dropFirst(prefix.count))
        }
        return namespace
    }

    static func sourceID(forServiceNamespace namespace: String) -> String {
        sourceID(for: "\(namespace):action")
    }
}

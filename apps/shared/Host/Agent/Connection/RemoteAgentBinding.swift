import Foundation

nonisolated struct AgentModelReference: Codable, Equatable, Hashable, Sendable {
    var provider: String
    var id: String
}

nonisolated enum ShellAccess: String, Codable, CaseIterable, Sendable {
    case off, ask, on

    var agentTools: [String] {
        self == .off ? Self.fileTools : Self.fileTools + ["bash"]
    }

    var confirmTools: [String] {
        self == .ask ? ["bash"] : []
    }

    private static let fileTools = ["read", "grep", "find", "ls", "edit", "write"]
}

nonisolated struct RemoteAgentBinding: Codable, Equatable, Sendable {
    var endpoint: URL
    var conversationID: String?
    var model: AgentModelReference?
    var thinkingLevel: String?
    var folder: String?
    var cwd: String?
    var shell: ShellAccess? = .ask
    var lastSeq: Int?
}

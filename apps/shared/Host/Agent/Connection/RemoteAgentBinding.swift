import Foundation

nonisolated struct AgentModelReference: Codable, Equatable, Hashable, Sendable {
    var provider: String
    var id: String
}

nonisolated struct RemoteAgentBinding: Codable, Equatable, Sendable {
    var endpoint: URL
    var conversationID: String?
    var model: AgentModelReference?
    var thinkingLevel: String?
    var folder: String?
    var lastSeq: Int?
}

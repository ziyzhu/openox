import Foundation

nonisolated struct ConversationSummary: Sendable {
    let id: UUID
    let title: String
    let model: String?
    let createdAt: Date
    let lastActivity: Date?
    let active: Bool
    let agent: RemoteAgentBinding?
    let pinned: Bool
    let scheduled: Bool
    let status: String
    let parentID: UUID?
}

@MainActor
protocol RuntimeAutomation {
    static func perform(_ method: ProfileProtocol.Method, params: JSONValue, reply: ProfileRPC.Reply) throws
}

@MainActor
protocol ProfileRuntime: AnyObject {
    var automation: (any RuntimeAutomation.Type)? { get }
    var state: RuntimeState { get }
    var executionAvailable: Bool { get }
    var conversations: ConversationManager { get }
    var services: ServiceManager { get }

    func listConversations() async -> [ConversationSummary]
    func prepareStorage() async throws
    func prepare() async throws
}

import Foundation

nonisolated struct ConversationSummary: Sendable {
    let id: UUID
    let title: String
    let model: String?
    let createdAt: Date
    let lastActivity: Date?
    let active: Bool
    let agent: RemoteAgentBinding?
}

@MainActor
protocol ProfileRuntime: AnyObject {
    var state: RuntimeState { get }
    var executionAvailable: Bool { get }
    var conversations: ConversationManager { get }
    var services: ServiceManager { get }

    func listConversations() async -> [ConversationSummary]
    func prepareStorage() async throws
    func prepare() async throws
}

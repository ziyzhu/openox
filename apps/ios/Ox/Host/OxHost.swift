import Foundation

nonisolated struct HostConversationSummary: Sendable {
    let id: UUID
    let title: String
    let model: String?
    let createdAt: Date
    let lastActivity: Date?
    let active: Bool
}

@MainActor
protocol OxHost: AnyObject {
    var state: HostState { get }
    var executionAvailable: Bool { get }
    var conversations: ConversationManager { get }
    var services: ServiceManager { get }

    func listConversations() -> [HostConversationSummary]
    func prepareStorage() async throws
    func prepare() async throws
}

import Foundation

nonisolated struct HostChatSummary: Sendable {
    let id: UUID
    let title: String
    let model: String?
    let createdAt: Date
    let lastActivity: Date?
    let active: Bool
}

@MainActor
protocol OxHost: AnyObject {
    var chats: ConversationManager { get }
    var services: ServiceManager { get }

    func listChats() -> [HostChatSummary]
    func prepareStorage() async throws
    func prepare() async throws
}

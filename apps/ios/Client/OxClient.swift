import Foundation

@MainActor
final class OxClient {
    static let shared = OxClient(host: IOSHost.shared)

    private let host: any OxHost
    let conversationReader: any HostConversationReading
    let conversationController: any HostConversationControlling

    var conversations: ConversationManager { host.conversations }
    var services: ServiceManager { host.services }

    func listConversations() async throws -> [HostConversationSummary] {
        try await conversationReader.listConversations()
    }

    func readConversation(_ id: UUID) async throws -> HostConversationState {
        try await conversationReader.readConversation(id)
    }

    func sendText(_ text: String, to id: UUID, mode: HostConversationSendMode) async throws -> HostConversationSendResult {
        try await conversationController.sendText(text, to: id, mode: mode)
    }

    func stopConversation(_ id: UUID) async throws -> HostConversationStopResult {
        try await conversationController.stopConversation(id)
    }

    func respondToPrompt(_ promptID: UUID, in id: UUID, answer: String) async throws -> UUID {
        try await conversationController.respondToPrompt(promptID, in: id, answer: answer)
    }

    init(
        host: any OxHost,
        conversationReader: (any HostConversationReading)? = nil,
        conversationController: (any HostConversationControlling)? = nil
    ) {
        self.host = host
        self.conversationReader = conversationReader ?? EmbeddedHostConversationReader(host: host)
        self.conversationController = conversationController ?? EmbeddedHostConversationController(host: host)
    }

    func setScheduleEnabled(_ enabled: Bool, id: UUID) async throws {
        try await host.setScheduleEnabled(enabled, id: id)
    }

    func deleteSchedule(_ id: UUID) async throws {
        try await host.deleteSchedule(id)
    }

    func prepareStorage() async throws {
        try await host.prepareStorage()
    }

    func prepare() async throws {
        try await host.prepare()
    }

    static func preview(serviceManager: ServiceManager) -> OxClient {
        OxClient(host: IOSHost(
            serviceManager: serviceManager,
            presentations: .unavailable
        ))
    }
}

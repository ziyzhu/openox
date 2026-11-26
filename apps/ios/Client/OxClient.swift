import Foundation

@MainActor
final class OxClient {
    static let shared = OxClient(runtime: IOSProfileRuntime.shared)

    private let runtime: any ProfileRuntime
    let conversationReader: any ConversationReading
    let conversationController: any ConversationControlling

    var conversations: ConversationManager { runtime.conversations }
    var services: ServiceManager { runtime.services }

    func listConversations() async throws -> [ConversationSummary] {
        try await conversationReader.listConversations()
    }

    func readConversation(_ id: UUID) async throws -> ConversationReadState {
        try await conversationReader.readConversation(id)
    }

    func sendText(_ text: String, to id: UUID, mode: ConversationSendMode) async throws -> ConversationSendResult {
        try await conversationController.sendText(text, to: id, mode: mode)
    }

    func stopConversation(_ id: UUID) async throws -> ConversationStopResult {
        try await conversationController.stopConversation(id)
    }

    func respondToPrompt(_ promptID: UUID, in id: UUID, answer: String) async throws -> UUID {
        try await conversationController.respondToPrompt(promptID, in: id, answer: answer)
    }

    init(
        runtime: any ProfileRuntime,
        conversationReader: (any ConversationReading)? = nil,
        conversationController: (any ConversationControlling)? = nil
    ) {
        self.runtime = runtime
        self.conversationReader = conversationReader ?? EmbeddedConversationReader(runtime: runtime)
        self.conversationController = conversationController ?? EmbeddedConversationController(runtime: runtime)
    }

    func updateSchedule(id: UUID, name: String, prompt: String, condition: String?, deadline: Date?, recurrence: ScheduleRecurrence) async throws {
        try await runtime.updateSchedule(id: id, name: name, prompt: prompt, condition: condition, deadline: deadline, recurrence: recurrence)
    }

    func setScheduleEnabled(_ enabled: Bool, id: UUID) async throws {
        try await runtime.setScheduleEnabled(enabled, id: id)
    }

    func deleteSchedule(_ id: UUID) async throws {
        try await runtime.deleteSchedule(id)
    }

    func prepareStorage() async throws {
        try await runtime.prepareStorage()
    }

    func prepare() async throws {
        try await runtime.prepare()
    }

    static func preview(serviceManager: ServiceManager) -> OxClient {
        OxClient(runtime: IOSProfileRuntime(
            serviceManager: serviceManager,
            presentations: .unavailable
        ))
    }
}

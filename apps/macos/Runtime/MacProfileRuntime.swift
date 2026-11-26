import Foundation

@MainActor
final class MacProfileRuntime: ProfileRuntime {
    private let runtime: SharedProfileRuntime

    var services: ServiceManager { runtime.services }
    var conversations: ConversationManager { runtime.conversations }
    var state: RuntimeState { runtime.state }
    var executionAvailable: Bool { runtime.executionAvailable }
    var automation: (any RuntimeAutomation.Type)? { nil }

    init() {
        StorageMigrator.migrateApp()
        runtime = SharedProfileRuntime(
            serviceManager: ServiceManager(nativeServices: MacNativeServiceCatalog()),
            presentations: MacAppPresentations().presentations,
            conversationExecution: MacConversationExecution(),
            conversationFeedback: MacConversationFeedback(),
            executionPolicy: { true },
            activateSchedules: { try await ScheduleScheduler.shared.activate() },
            deactivateSchedules: { await ScheduleScheduler.shared.stop() }
        )
    }

    func listConversations() async -> [ConversationSummary] { await runtime.listConversations() }

    func prepareStorage() async throws {
        try await runtime.prepareStorage()
    }

    func prepare() async throws {
        try await runtime.prepare()
    }
}

import AppKit

@MainActor
final class MacProfileRuntime: ProfileRuntime {
    private let runtime: SharedProfileRuntime
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var connectionLifecycleTask: Task<Void, Never>?

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
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleepChanged(asleep: true) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleepChanged(asleep: false) }
            },
        ]
    }

    private func sleepChanged(asleep: Bool) {
        Log.app.info("MacProfileRuntime.\(asleep ? "sleep" : "wake")")
        conversations.suspendModelPreparation()
        connectionLifecycleTask?.cancel()
        connectionLifecycleTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await OpenAIResponsesWebSocketPool.shared.setActivity(asleep ? .background : .foreground)
            guard !Task.isCancelled, !asleep else { return }
            conversations.resumeAfterForeground()
        }
    }

    deinit {
        connectionLifecycleTask?.cancel()
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func listConversations() async -> [ConversationSummary] { await runtime.listConversations() }

    func prepareStorage() async throws {
        try await runtime.prepareStorage()
    }

    func prepare() async throws {
        try await runtime.prepare()
    }
}

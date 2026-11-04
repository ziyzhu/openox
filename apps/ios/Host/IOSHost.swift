import Foundation
import UIKit

@MainActor
final class IOSHost: OxHost {
    static let shared = IOSHost()

    private let runtime: HostRuntime
    private var recoveryObservers: [NSObjectProtocol] = []
    private var connectionLifecycleTask: Task<Void, Never>?

    var services: ServiceManager { runtime.services }
    var conversations: ConversationManager { runtime.conversations }
    var state: HostState { runtime.state }
    var executionAvailable: Bool { runtime.executionAvailable }

    convenience init() {
        StorageMigrator.migrateApplicationStorage()
        self.init(preparedServices: ServiceManager(), presentations: .live)
    }

    convenience init(serviceManager: ServiceManager, presentations: AppPresentations) {
        StorageMigrator.migrateApplicationStorage()
        serviceManager.reloadPersistedStorage()
        self.init(preparedServices: serviceManager, presentations: presentations)
    }

    private init(preparedServices: ServiceManager, presentations: AppPresentations) {
        runtime = HostRuntime(
            serviceManager: preparedServices,
            presentations: presentations,
            conversationExecution: IOSConversationExecution(),
            conversationFeedback: IOSConversationFeedback(),
            executionPolicy: { UIApplication.shared.applicationState == .active },
            activateSchedules: { try await ScheduleScheduler.shared.activate() },
            deactivateSchedules: { await ScheduleScheduler.shared.stop() }
        )
        recoveryObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.executionAvailabilityChanged() }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.executionAvailabilityChanged()
                    self?.conversations.notifyPendingInteractions()
                }
            },
        ]
        executionAvailabilityChanged()
    }

    private func executionAvailabilityChanged() {
        runtime.executionAvailabilityChanged()
        conversations.suspendModelPreparation()
        connectionLifecycleTask?.cancel()
        connectionLifecycleTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await OpenAIResponsesWebSocketPool.shared.setActivity(executionAvailable ? .foreground : .background)
            guard !Task.isCancelled, executionAvailable else { return }
            conversations.resumeAfterForeground()
        }
    }

    deinit {
        connectionLifecycleTask?.cancel()
        for observer in recoveryObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func listConversations() async -> [HostConversationSummary] { await runtime.listConversations() }

    func prepareStorage() async throws {
        try await runtime.prepareStorage()
    }

    func prepare() async throws {
        try await runtime.prepare()
    }
}

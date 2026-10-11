import Foundation
import UIKit

@MainActor
final class IOSHost: OxHost {
    static let shared = IOSHost()

    private let runtime: HostRuntime
    private var recoveryObservers: [NSObjectProtocol] = []

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
            executionPolicy: {
                #if targetEnvironment(macCatalyst)
                true
                #else
                UIApplication.shared.applicationState == .active
                #endif
            }
        )
        recoveryObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runtime.executionAvailabilityChanged() }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runtime.executionAvailabilityChanged() }
            },
        ]
    }

    deinit {
        for observer in recoveryObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func listConversations() -> [HostConversationSummary] { runtime.listConversations() }

    func prepareStorage() async throws {
        try await runtime.prepareStorage()
    }

    func prepare() async throws {
        try await runtime.prepare()
    }
}

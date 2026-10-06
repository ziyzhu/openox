import Foundation
import UIKit

@MainActor
final class IOSHost: OxHost {
    private struct PreparedStorage {}

    private struct Preparation {
        let storage: Task<Void, Error>
        let profile: Task<Void, Error>
    }

    static let shared = IOSHost()

    let services: ServiceManager
    let conversations: ConversationManager

    private var preparation: Preparation?
    private var optionalRecovery: Task<Void, Never>?
    private var recoveryObservers: [NSObjectProtocol] = []

    convenience init() {
        StorageMigrator.migrateApplicationStorage()
        self.init(serviceManager: ServiceManager(), presentations: .live, storage: PreparedStorage())
    }

    convenience init(serviceManager: ServiceManager, presentations: AppPresentations) {
        StorageMigrator.migrateApplicationStorage()
        serviceManager.reloadPersistedStorage()
        self.init(serviceManager: serviceManager, presentations: presentations, storage: PreparedStorage())
    }

    private init(
        serviceManager: ServiceManager,
        presentations: AppPresentations,
        storage _: PreparedStorage
    ) {
        services = serviceManager
        conversations = ConversationManager(
            repository: .shared,
            storage: .shared,
            providerRegistry: .shared,
            serviceManager: serviceManager,
            presentations: presentations
        )
        conversations.profilePreparation = { [weak self] in await self?.waitUntilProfilePrepared() }
        recoveryObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeOptionalStorageRecovery() }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseOptionalStorageRecovery() }
            },
        ]
    }

    deinit {
        optionalRecovery?.cancel()
        for observer in recoveryObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func listChats() -> [HostChatSummary] {
        conversations.orderedSummaries.map { summary in
            HostChatSummary(
                id: summary.id,
                title: summary.displayTitle,
                model: summary.modelID,
                createdAt: summary.createdAt,
                lastActivity: summary.lastActivity,
                active: summary.id == conversations.currentId
            )
        }
    }

    func prepareStorage() async throws {
        try await awaitPreparation(\.storage)
    }

    func prepare() async throws {
        try await awaitPreparation(\.profile)
    }

    private func pauseOptionalStorageRecovery() {
        optionalRecovery?.cancel()
    }

    private func resumeOptionalStorageRecovery() {
        guard UIApplication.shared.applicationState == .active else { return }
        if let current = optionalRecovery {
            if current.isCancelled {
                Task {
                    await current.value
                    resumeOptionalStorageRecovery()
                }
            }
            return
        }
        guard let profile = preparation?.profile,
              services.localRecoveryMessage != nil || ScheduledSkills.shared.preparation?.failureMessage != nil else { return }
        optionalRecovery = Task { @MainActor in
            defer { optionalRecovery = nil }
            do {
                try await profile.value
                var delay: Double = 2
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(delay))
                    if await StorageMigrator.recoverOptionalStorage(services: services) { return }
                    delay = min(delay * 3, 300)
                }
            } catch is CancellationError {
            } catch {
                Log.app.error("IOSHost optionalRecovery blocked error=\(error.localizedDescription)")
            }
        }
    }

    private func waitUntilProfilePrepared() async {
        _ = try? await preparation?.profile.value
    }

    private func awaitPreparation(_ stage: KeyPath<Preparation, Task<Void, Error>>) async throws {
        let current = preparation ?? beginPreparation()
        do {
            try await current[keyPath: stage].value
        } catch {
            if preparation?.profile == current.profile { preparation = nil }
            throw error
        }
    }

    private func beginPreparation() -> Preparation {
        let services = services
        let conversations = conversations
        let storage = Task { @MainActor in
            try await StorageMigrator.prepare(storage: .shared, services: services)
            Log.app.info("IOSHost storage prepared")
        }
        let profile = Task { @MainActor in
            try await storage.value
            #if DEBUG && targetEnvironment(simulator)
            if SimEnv.startupDelayMilliseconds > 0 {
                Log.app.info("IOSHost profile delayMs=\(SimEnv.startupDelayMilliseconds)")
                try await Task.sleep(for: .milliseconds(SimEnv.startupDelayMilliseconds))
            }
            #endif
            await conversations.loadSummariesNow()
            _ = Soul.shared
            _ = UserMemory.shared
            try await UserMemory.shared.waitUntilCurrent()
            await services.refreshServices(locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region))
            do { try ScheduledSkillScheduler.shared.activate() }
            catch { Log.app.warning("IOSHost schedules unavailable recoveryRequired=true error=\(error.localizedDescription)") }
            Log.app.info("IOSHost profile prepared")
            resumeOptionalStorageRecovery()
        }
        let preparation = Preparation(storage: storage, profile: profile)
        self.preparation = preparation
        return preparation
    }
}

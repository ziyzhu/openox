@MainActor
final class IOSHost: OxHost {
    private struct PreparedStorage {}

    private struct Preparation {
        let storage: Task<Void, Error>
        let profile: Task<Void, Error>
    }

    static let shared = IOSHost()

    let services: ServiceManager
    let chats: ConversationManager

    private var preparation: Preparation?

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
        chats = ConversationManager(
            repository: .shared,
            storage: .shared,
            providerRegistry: .shared,
            serviceManager: serviceManager,
            presentations: presentations
        )
        chats.profilePreparation = { [weak self] in await self?.waitUntilProfilePrepared() }
    }

    func listChats() -> [HostChatSummary] {
        chats.orderedSummaries.map { summary in
            HostChatSummary(
                id: summary.id,
                title: summary.displayTitle,
                model: summary.modelID,
                createdAt: summary.createdAt,
                lastActivity: summary.lastActivity,
                active: summary.id == chats.currentId
            )
        }
    }

    func prepareStorage() async throws {
        try await awaitPreparation(\.storage)
    }

    func prepare() async throws {
        try await awaitPreparation(\.profile)
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
        let chats = chats
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
            await chats.loadSummariesNow()
            _ = Soul.shared
            _ = UserMemory.shared
            try await UserMemory.shared.waitUntilCurrent()
            await services.refreshServices(locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region))
            try ScheduledSkillScheduler.shared.activate()
            Log.app.info("IOSHost profile prepared")
        }
        let preparation = Preparation(storage: storage, profile: profile)
        self.preparation = preparation
        return preparation
    }
}

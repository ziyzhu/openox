enum HostPreparationPhase {
    case opening
    case updating
    case loadingChats
}

@MainActor
final class IOSHost: OxHost {
    private struct PreparedStorage {}

    static let shared = IOSHost()

    let services: ServiceManager
    let chats: ChatManager

    private var preparationTask: Task<Void, Error>?
    private var isPrepared = false

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
        chats = ChatManager(
            repository: .shared,
            storage: .shared,
            llmRegistry: .shared,
            serviceManager: serviceManager,
            presentations: presentations
        )
    }

    func prepare(onPhase: (@MainActor (HostPreparationPhase) -> Void)? = nil) async throws {
        if isPrepared { return }
        if let preparationTask {
            try await preparationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            onPhase?(.opening)
            onPhase?(.updating)
            try await StorageMigrator.prepare(storage: .shared, services: services)
            onPhase?(.loadingChats)
            await chats.loadSummariesNow()
            _ = Soul.shared
            _ = UserMemory.shared
            await UserMemory.shared.waitUntilCurrent()
            try ScheduledSkillScheduler.shared.activate()
            isPrepared = true
            Log.app.info("IOSHost prepared")
        }
        preparationTask = task
        defer { preparationTask = nil }
        try await task.value
    }
}

enum HostPreparationPhase {
    case opening
    case updating
    case loadingChats
}

@MainActor
final class IOSHost: OxHost {
    static let shared = IOSHost()

    let services: ServiceManager
    let chats: ChatManager

    private var preparationTask: Task<Void, Never>?
    private var isPrepared = false

    convenience init() {
        self.init(serviceManager: ServiceManager(), presentations: .live)
    }

    init(serviceManager: ServiceManager, presentations: AppPresentations) {
        services = serviceManager
        chats = ChatManager(
            repository: .shared,
            storage: .shared,
            llmRegistry: .shared,
            serviceManager: serviceManager,
            presentations: presentations
        )
    }

    func prepare(onPhase: (@MainActor (HostPreparationPhase) -> Void)? = nil) async {
        if isPrepared { return }
        if let preparationTask {
            await preparationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            onPhase?(.opening)
            await StorageRoot.shared.resolve()
            onPhase?(.updating)
            await StorageRoot.shared.migrateActive()
            onPhase?(.loadingChats)
            await chats.loadSummariesNow()
            _ = Soul.shared
            _ = UserMemory.shared
            await UserMemory.shared.waitUntilCurrent()
            isPrepared = true
            Log.app.info("IOSHost prepared")
        }
        preparationTask = task
        await task.value
        preparationTask = nil
    }
}

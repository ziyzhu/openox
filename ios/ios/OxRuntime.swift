import Foundation

@MainActor
final class OxRuntime {
    enum PreparationPhase {
        case opening
        case updating
        case loadingChats
    }

    static let shared = OxRuntime()

    let serviceManager: ServiceManager
    let chatManager: ChatManager

    private var preparationTask: Task<Void, Never>?
    private var isPrepared = false

    convenience init() {
        self.init(serviceManager: ServiceManager(), presentations: .live)
    }

    init(serviceManager: ServiceManager, presentations: AppPresentations) {
        self.serviceManager = serviceManager
        chatManager = ChatManager(
            repository: .shared,
            storage: .shared,
            llmRegistry: .shared,
            serviceManager: serviceManager,
            presentations: presentations
        )
    }

    func prepare(onPhase: (@MainActor (PreparationPhase) -> Void)? = nil) async {
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
            await chatManager.loadSummariesNow()
            _ = Soul.shared
            _ = UserMemory.shared
            await UserMemory.shared.waitUntilCurrent()
            isPrepared = true
            Log.app.info("OxRuntime prepared")
        }
        preparationTask = task
        await task.value
        preparationTask = nil
    }
}

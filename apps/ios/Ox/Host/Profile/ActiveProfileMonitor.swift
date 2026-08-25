import Foundation

nonisolated enum ProfileContentArea: String, CaseIterable, Sendable {
    case configuration
    case soul
    case memory
    case skills
    case chats
    case artifacts

    static let all = Set(allCases)

    static func affected(by url: URL?, under root: URL) -> Set<Self> {
        guard let url else { return all }
        let rootComponents = root.standardizedFileURL.pathComponents
        let itemComponents = url.standardizedFileURL.pathComponents
        guard itemComponents.starts(with: rootComponents), itemComponents.count > rootComponents.count else {
            return all
        }
        switch itemComponents[rootComponents.count] {
        case "MEMORY.md": return [.memory]
        case "SOUL.md": return [.soul]
        case "skills": return [.skills]
        case "chats": return [.chats]
        case "artifacts": return [.artifacts]
        default: return [.configuration]
        }
    }
}

private final class ProfileDirectoryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let changed: @Sendable (URL?) -> Void

    init(url: URL, changed: @escaping @Sendable (URL?) -> Void) {
        presentedItemURL = url
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue.qualityOfService = .utility
        self.changed = changed
    }

    func presentedItemDidChange() {
        changed(presentedItemURL)
    }

    func presentedSubitemDidAppear(at url: URL) {
        changed(url)
    }

    func presentedSubitemDidChange(at url: URL) {
        changed(url)
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        changed(oldURL)
        changed(newURL)
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        changed(url)
        completionHandler(nil)
    }
}

@MainActor
final class ActiveProfileMonitor {
    private var presenter: ProfileDirectoryPresenter?
    private var artifactMetadataQuery: NSMetadataQuery?
    private var artifactMetadataObservers: [NSObjectProtocol] = []
    private var root: URL?
    private var pending: Set<ProfileContentArea> = []
    private var debounceTask: Task<Void, Never>?
    private var changed: ((Set<ProfileContentArea>) -> Void)?

    func activate(scope: ProfileScope, changed: @escaping (Set<ProfileContentArea>) -> Void) {
        if root == scope.root, presenter != nil {
            self.changed = changed
            return
        }
        deactivate()
        root = scope.root
        self.changed = changed
        let root = scope.root
        let presenter = ProfileDirectoryPresenter(url: root) { [weak self] url in
            Task { @MainActor [weak self] in
                self?.record(ProfileContentArea.affected(by: url, under: root))
            }
        }
        self.presenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
        if scope.location == .iCloud { startArtifactMetadataQuery(in: scope) }
        Log.app.info("ActiveProfileMonitor.activate root=\(root.lastPathComponent) generation=\(scope.generation)")
    }

    func deactivate() {
        debounceTask?.cancel()
        debounceTask = nil
        pending = []
        changed = nil
        root = nil
        artifactMetadataQuery?.stop()
        artifactMetadataQuery = nil
        artifactMetadataObservers.forEach(NotificationCenter.default.removeObserver)
        artifactMetadataObservers = []
        guard let presenter else { return }
        NSFileCoordinator.removeFilePresenter(presenter)
        self.presenter = nil
        Log.app.info("ActiveProfileMonitor.deactivate")
    }

    private func record(_ areas: Set<ProfileContentArea>) {
        pending.formUnion(areas)
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let areas = pending
            pending = []
            let names = areas.map(\.rawValue).sorted().joined(separator: ",")
            Log.app.info("ActiveProfileMonitor.changed areas=\(names)")
            changed?(areas)
        }
    }

    private func startArtifactMetadataQuery(in scope: ProfileScope) {
        let directory = scope.root.appendingPathComponent("artifacts", isDirectory: true)
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            directory.path + "/"
        )
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            artifactMetadataObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: query,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.record([.artifacts]) }
            })
        }
        artifactMetadataQuery = query
        query.start()
    }
}

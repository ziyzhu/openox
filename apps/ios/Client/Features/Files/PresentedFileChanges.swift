import SwiftUI

nonisolated private final class PresentedFile: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let changed: @Sendable () -> Void

    init(url: URL, changed: @escaping @Sendable () -> Void) {
        presentedItemURL = url
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue.qualityOfService = .utility
        self.changed = changed
    }

    func presentedItemDidChange() {
        changed()
    }
}

extension View {
    func onPresentedFileChange(_ url: URL, perform action: @escaping @MainActor () -> Void) -> some View {
        task(id: url) {
            let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let presenter = PresentedFile(url: url) { continuation.yield() }
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            for await _ in changes {
                action()
            }
        }
    }
}

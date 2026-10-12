import UIKit
import UniformTypeIdentifiers

nonisolated enum FolderBookmarks {
    static func make(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil)
    }

    static func resolve(_ data: Data, stale: inout Bool) throws -> URL {
        try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }
}

@MainActor
enum HostFolderPicker {
    static func choose() async throws -> URL {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow),
              var presenter = window.rootViewController else { throw RuntimeError.bridge("No active Host window for folder access") }
        while let presented = presenter.presentedViewController { presenter = presented }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        let delegate = FolderPickerDelegate()
        picker.delegate = delegate
        return try await withCheckedThrowingContinuation { continuation in
            delegate.completion = { result in
                withExtendedLifetime(delegate) { continuation.resume(with: result) }
            }
            presenter.present(picker, animated: true)
        }
    }
}

@MainActor
private final class FolderPickerDelegate: NSObject, UIDocumentPickerDelegate {
    var completion: ((Result<URL, Error>) -> Void)?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first.map { .success($0) } ?? .failure(CancellationError()))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

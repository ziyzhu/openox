import AppKit

nonisolated enum FolderBookmarks {
    static func make(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil)
    }

    static func resolve(_ data: Data, stale: inout Bool) throws -> URL {
        try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
    }
}

@MainActor
enum HostFolderPicker {
    static func choose() async throws -> URL {
        let panel = NSOpenPanel()
        panel.title = "Mount folder — Ox Host"
        panel.message = "Allow Ox to access this folder through the Files service."
        panel.prompt = "Mount Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApplication.shared.activate()
        return try await withCheckedThrowingContinuation { continuation in
            panel.begin { response in
                if response == .OK, let url = panel.url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: CancellationError()) }
            }
        }
    }
}

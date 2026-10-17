import Foundation

nonisolated enum FileStaging {
    static func uniqueURL(in parent: URL, prefix: String, isDirectory: Bool) -> URL {
        parent.appendingPathComponent(".\(prefix)-\(UUID().uuidString)", isDirectory: isDirectory)
    }

    static func createDirectory(in parent: URL, prefix: String) throws -> URL {
        let url = uniqueURL(in: parent, prefix: prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func cleanup(_ url: URL, operation: String) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        do {
            try manager.removeItem(at: url)
        } catch {
            Log.app.error("FileStaging.cleanup operation=\(operation) item=\(url.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }
}

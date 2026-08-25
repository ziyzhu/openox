import Foundation

nonisolated enum SharedNoteInbox {
    struct Outcome: Sendable {
        let imported: [Artifact]
        let failures: [String]
    }

    static func consume(in scope: ProfileScope) async -> Outcome {
        let payloads: [(directory: URL, file: URL)]
        do {
            payloads = try await Task.detached(priority: .utility) { try pendingPayloads() }.value
        } catch {
            return Outcome(imported: [], failures: [error.localizedDescription])
        }
        var imported: [Artifact] = []
        var failures: [String] = []
        for payload in payloads {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: payload.file)
                }.value
                let artifact = try await ArtifactImporter.importDataAsync(
                    data,
                    suggestedName: payload.file.lastPathComponent,
                    in: scope
                )
                imported.append(artifact)
                try await Task.detached(priority: .utility) {
                    try FileManager.default.removeItem(at: payload.directory)
                }.value
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return Outcome(imported: imported, failures: failures)
    }

    #if targetEnvironment(simulator)
    static func stageForTesting(title: String, text: String) throws {
        let directory = try pendingDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = ArtifactStore.sanitizedFilename(title) + ".md"
        try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    #endif

    private static func pendingPayloads() throws -> [(directory: URL, file: URL)] {
        let manager = FileManager.default
        let pending = try pendingDirectory()
        try manager.createDirectory(at: pending, withIntermediateDirectories: true)
        return try manager.contentsOfDirectory(
            at: pending,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let file = try? manager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ).first(where: {
                      (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                  }) else { return nil }
            return (directory, file)
        }
    }

    private static func pendingDirectory() throws -> URL {
        try AppStoragePaths.pendingShareImportsDirectory()
    }
}

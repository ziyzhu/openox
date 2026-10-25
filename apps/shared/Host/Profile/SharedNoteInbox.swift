import Foundation

nonisolated enum SharedNoteInbox {
    struct Outcome: Sendable {
        let files: [(staged: FileImporter.StagedFile, directory: URL)]
        let failures: [String]

        var staged: [FileImporter.StagedFile] { files.map(\.staged) }

        func acknowledge() async -> [String] {
            await Task.detached(priority: .utility) {
                var failures: [String] = []
                for file in files {
                    do { try FileManager.default.removeItem(at: file.directory) }
                    catch { failures.append(error.localizedDescription) }
                }
                return failures
            }.value
        }
    }

    static func consume() async -> Outcome {
        let payloads: [(directory: URL, file: URL)]
        do {
            payloads = try await Task.detached(priority: .utility) { try pendingPayloads() }.value
        } catch {
            return Outcome(files: [], failures: [error.localizedDescription])
        }
        var files: [(staged: FileImporter.StagedFile, directory: URL)] = []
        var failures: [String] = []
        for payload in payloads {
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    let draft = try FileImporter.dataDraft(Data(contentsOf: payload.file), suggestedName: payload.file.lastPathComponent)
                    return try FileImporter.stage(draft)
                }.value
                files.append((file, payload.directory))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return Outcome(files: files, failures: failures)
    }

    static func stageForTesting(title: String, text: String) throws {
        let directory = try pendingDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = FileStore.sanitizedFilename(title) + ".md"
        try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

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

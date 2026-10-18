import Foundation

nonisolated struct FileMetadata: Codable, Sendable {
    let id: UUID
    let fileName: String
    let displayName: String
    let mimeType: String
    let kind: FileItem.Kind
}

@MainActor
private final class UbiquitousFileQuery {
    private let directory: URL
    private let query = NSMetadataQuery()
    private var continuation: CheckedContinuation<[FileItem], Never>?
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    static func run(in directory: URL) async -> [FileItem] {
        await UbiquitousFileQuery(directory: directory).run()
    }

    private func run() async -> [FileItem] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(
                format: "%K BEGINSWITH %@",
                NSMetadataItemPathKey,
                directory.path + "/"
            )
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish() }
            }
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish()
            }
            if !query.start() { finish() }
        }
    }

    private func finish() {
        guard let continuation else { return }
        query.disableUpdates()
        let artifacts = query.results.compactMap { result -> FileItem? in
            guard let item = result as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.deletingLastPathComponent().standardizedFileURL == directory,
                  !url.lastPathComponent.starts(with: ".") else { return nil }
            let typeTree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
            guard !typeTree.contains("public.folder") else { return nil }
            let error = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingErrorKey) as? Error
            let isDownloading = item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool ?? false
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let availability: FileItem.Availability
            if error != nil {
                availability = .unavailable
            } else if isDownloading {
                availability = .downloading
            } else if status == URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue {
                availability = .cloudOnly
            } else {
                availability = .local
            }
            return FileItem(
                fileName: url.lastPathComponent,
                directory: directory,
                availability: availability,
                size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.intValue,
                createdAt: item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date,
                modifiedAt: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            )
        }
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timeoutTask?.cancel()
        self.observer = nil
        timeoutTask = nil
        self.continuation = nil
        continuation.resume(returning: artifacts)
    }
}

nonisolated enum FileStore {
    static let metadataName = "artifact.json"
    private static let savedIndexName = ".saved.json"

    static func artifact(
        named name: String,
        in directory: URL,
        listing: FileDirectoryListing = FileDirectoryListing()
    ) throws -> FileItem {
        let requested = try validatedFilename(name)
        let resolved = listing.existingFilename(matching: requested, in: directory) ?? requested
        return FileItem(fileName: resolved, directory: directory)
    }

    static func list(in directory: URL) -> [FileItem] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
                .ubiquitousItemDownloadingErrorKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { file in
            artifact(at: file, in: directory)
        }
    }

    static func listIncludingUbiquitousItems(in directory: URL) async -> [FileItem] {
        let local = list(in: directory)
        let ubiquitous = await UbiquitousFileQuery.run(in: directory)
        var merged = Dictionary(uniqueKeysWithValues: ubiquitous.map { ($0.fileName.lowercased(), $0) })
        for artifact in local {
            merged[artifact.fileName.lowercased()] = artifact
        }
        return merged.values.sorted {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    private static func artifact(at file: URL, in directory: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingErrorKey,
        ]
        guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
        let availability: FileItem.Availability
        if values.ubiquitousItemDownloadingError != nil {
            availability = .unavailable
        } else if values.ubiquitousItemIsDownloading == true {
            availability = .downloading
        } else if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            availability = .cloudOnly
        } else {
            availability = .local
        }
        #if targetEnvironment(simulator)
        let resolvedAvailability: FileItem.Availability = SimEnv.cloudOnlyFiles.contains(file.lastPathComponent)
            ? .cloudOnly
            : availability
        #else
        let resolvedAvailability = availability
        #endif
        return FileItem(
            fileName: file.lastPathComponent,
            directory: directory,
            availability: resolvedAvailability,
            size: values.fileSize,
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate
        )
    }

    static func savedNames(in directory: URL) -> Set<String> {
        let index = directory.appendingPathComponent(savedIndexName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        do {
            return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: index)))
        } catch {
            Log.app.error("FileStore.savedNames failed=\(error.localizedDescription)")
            return []
        }
    }

    static func setSaved(_ saved: Bool, name: String, directory: URL) throws {
        let artifact = try requiredFile(named: name, in: directory)
        var names = savedNames(in: directory)
        names = Set(names.filter { $0.caseInsensitiveCompare(artifact.fileName) != .orderedSame })
        if saved { names.insert(artifact.fileName) }
        try writeSavedNames(names, in: directory)
    }

    static func writeImported(data: Data, suggestedName: String, directory: URL) throws -> FileItem {
        let fileName = uniqueFilename(suggestedName, in: directory)
        let artifact = FileItem(fileName: fileName, directory: directory)
        try data.write(to: artifact.fileURL, options: .atomic)
        return artifact
    }

    static func write(data: Data, named name: String, directory: URL) throws -> FileItem {
        let requested = try validatedFilename(name)
        let fileName = existingFilename(matching: requested, in: directory) ?? requested
        let artifact = FileItem(fileName: fileName, directory: directory)
        try data.write(to: artifact.fileURL, options: .atomic)
        return artifact
    }

    static func edit(name: String, find: String, replace: String, directory: URL) throws -> FileItem {
        let artifact = try requiredFile(named: name, in: directory)
        let data = try Data(contentsOf: artifact.fileURL)
        guard data.count <= FileLimits.textBytes else {
            throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
        }
        guard let current = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
        let updated: String
        if find.isEmpty {
            updated = current + replace
        } else {
            let matches = ExactTextReplacement.count(find, in: current)
            guard matches > 0 else { throw FileError.textNotFound }
            guard matches == 1 else { throw FileError.textAmbiguous(matches: matches) }
            updated = ExactTextReplacement.replace(find, with: replace, in: current)
        }
        let updatedData = Data(updated.utf8)
        guard updatedData.count <= FileLimits.textBytes else {
            throw FileError.textTooLarge(bytes: updatedData.count, limit: FileLimits.textBytes)
        }
        try updatedData.write(to: artifact.fileURL, options: .atomic)
        return artifact
    }

    static func rename(_ name: String, to newName: String, directory: URL) throws -> FileItem {
        let source = try requiredFile(named: name, in: directory)
        let requested = try validatedFilename(newName)
        if source.fileName == requested { return source }
        if let collision = existingFilename(matching: requested, in: directory), collision != source.fileName {
            throw FileError.filenameExists(collision)
        }
        let savedNames = savedNames(in: directory)
        let wasSaved = savedNames.contains { $0.caseInsensitiveCompare(source.fileName) == .orderedSame }
        if wasSaved {
            var renamedNames = savedNames
            renamedNames = Set(renamedNames.filter { $0.caseInsensitiveCompare(source.fileName) != .orderedSame })
            renamedNames.insert(requested)
            try writeSavedNames(renamedNames, in: directory)
        }
        let destination = directory.appendingPathComponent(requested, isDirectory: false)
        do {
            if source.fileName.caseInsensitiveCompare(requested) == .orderedSame {
                let temporary = FileStaging.uniqueURL(in: directory, prefix: "rename", isDirectory: false)
                try FileManager.default.moveItem(at: source.fileURL, to: temporary)
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch {
                    try? FileManager.default.moveItem(at: temporary, to: source.fileURL)
                    throw error
                }
            } else {
                try FileManager.default.moveItem(at: source.fileURL, to: destination)
            }
        } catch {
            if wasSaved { try? writeSavedNames(savedNames, in: directory) }
            throw error
        }
        return FileItem(fileName: requested, directory: directory)
    }

    static func remove(_ name: String, directory: URL) throws -> FileItem {
        let artifact = try requiredFile(named: name, in: directory)
        let savedNames = savedNames(in: directory)
        let wasSaved = savedNames.contains { $0.caseInsensitiveCompare(artifact.fileName) == .orderedSame }
        if wasSaved {
            var remainingNames = savedNames
            remainingNames = Set(remainingNames.filter { $0.caseInsensitiveCompare(artifact.fileName) != .orderedSame })
            try writeSavedNames(remainingNames, in: directory)
        }
        do {
            try FileManager.default.removeItem(at: artifact.fileURL)
        } catch {
            if wasSaved { try? writeSavedNames(savedNames, in: directory) }
            throw error
        }
        return artifact
    }

    private static func writeSavedNames(_ names: Set<String>, in directory: URL) throws {
        let index = directory.appendingPathComponent(savedIndexName, isDirectory: false)
        let data = try JSONEncoder().encode(names.sorted())
        try data.write(to: index, options: .atomic)
    }

    static func uniqueFilename(_ suggestedName: String, in directory: URL) -> String {
        let cleaned = sanitizedFilename(suggestedName)
        let url = URL(fileURLWithPath: cleaned)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var candidate = cleaned
        var suffix = 2
        while existingFilename(matching: candidate, in: directory) != nil {
            candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    static func sanitizedFilename(_ suggestedName: String) -> String {
        let normalized = suggestedName.precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let pieces = normalized.components(separatedBy: forbidden)
        var value = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "." || value == ".." { value = "File" }
        if value.count > 180 { value = String(value.prefix(180)) }
        return value
    }

    static func validatedFilename(_ name: String) throws -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.caseInsensitiveCompare(savedIndexName) != .orderedSame,
              normalized == URL(fileURLWithPath: normalized).lastPathComponent,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:").union(.controlCharacters)) == nil else {
            throw FileError.invalidFilename(name)
        }
        return normalized
    }

    static func existingFilename(matching name: String, in directory: URL) -> String? {
        FileDirectoryListing().existingFilename(matching: name, in: directory)
    }

    private static func requiredFile(named name: String, in directory: URL) throws -> FileItem {
        let requested = try validatedFilename(name)
        guard let existing = existingFilename(matching: requested, in: directory) else {
            throw FileError.missing(requested)
        }
        let artifact = FileItem(fileName: existing, directory: directory)
        guard artifact.exists else { throw FileError.missing(requested) }
        return artifact
    }
}

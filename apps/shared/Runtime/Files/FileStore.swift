import Foundation

nonisolated struct FileMetadata: Codable, Sendable {
    let id: UUID
    let fileName: String
    let displayName: String
    let mimeType: String
    let kind: FileItem.Kind
}

nonisolated enum FileStore {
    static let metadataName = "artifact.json"
    private static let savedIndexName = ".saved.json"

    static func file(
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
        return files.compactMap { url in
            file(at: url, in: directory)
        }
    }

    private static func file(at file: URL, in directory: URL) -> FileItem? {
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
}

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

extension Notification.Name {
    static let artifactChanged = Notification.Name("ai.oxcraft.artifactChanged")
}

nonisolated extension CodingUserInfoKey {
    static let profileScope = CodingUserInfoKey(rawValue: "profileScope")!
    static let artifactDirectoryListing = CodingUserInfoKey(rawValue: "artifactDirectoryListing")!
}

nonisolated final class FileDirectoryListing: Sendable {
    private let names = Mutex<[URL: [String]]>([:])
    let files: [String: FileItem]?

    init(files: [String: FileItem]? = nil) { self.files = files }

    func existingFilename(matching name: String, in directory: URL) -> String? {
        let listed = names.withLock { names in
            if let listed = names[directory] { return listed }
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            names[directory] = listed
            return listed
        }
        return listed.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

nonisolated public struct FileItem: Equatable, Sendable, Identifiable, Codable {
    nonisolated public enum Availability: String, Sendable, Equatable, Codable {
        case local
        case cloudOnly
        case downloading
        case unavailable
    }

    nonisolated public enum Kind: String, Sendable, Equatable, Codable {
        case image
        case pdf
        case text
        case html
        case file
    }

    public let fileName: String
    public let fileURL: URL
    public let availability: Availability
    private let listedSize: Int?
    private let listedCreatedAt: Date?
    private let listedModifiedAt: Date?

    public var id: String { fileName }
    public var displayName: String { fileURL.lastPathComponent }
    public var userFacingName: String { displayName }
    public var userFacingTypeName: String? {
        if kind == .html { return L10n.string("HTML") }
        if isMarkdown { return L10n.string("Markdown") }
        return contentType.localizedDescription
    }
    public var availabilityDescription: String? {
        switch availability {
        case .local: nil
        case .cloudOnly: L10n.string("In iCloud")
        case .downloading: L10n.string("Downloading…")
        case .unavailable: L10n.string("Unavailable")
        }
    }
    public var userFacingAccessibilityLabel: String {
        [userFacingName, userFacingTypeName, availabilityDescription]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
    public var typeIdentifier: String { contentType.identifier }
    public var mimeType: String { contentType.preferredMIMEType ?? "application/octet-stream" }
    public var isMarkdown: Bool {
        let suffix = fileURL.pathExtension.lowercased()
        return contentType.identifier == "net.daringfireball.markdown"
            || suffix == "md"
            || suffix == "markdown"
    }
    public var isVideo: Bool { contentType.conforms(to: .movie) }
    public var usesDedicatedPreview: Bool { kind == .html || isMarkdown }
    public var usesZoomablePreview: Bool { !usesDedicatedPreview }
    public func fileName(forUserFacingName name: String) -> String { name }
    func updatingAvailability(_ availability: Availability) -> FileItem {
        FileItem(
            fileName: fileName,
            directory: fileURL.deletingLastPathComponent(),
            relativePath: fileURL.lastPathComponent,
            availability: availability,
            size: listedSize,
            createdAt: listedCreatedAt,
            modifiedAt: listedModifiedAt
        )
    }
    public static func userFacingName(forFileName fileName: String) -> String { fileName }
    public func userFacingErrorDescription(_ error: Error) -> String {
        guard let artifactError = error as? FileError else { return error.localizedDescription }
        let presentedError = switch artifactError {
        case .unsupportedType(let value): FileError.unsupportedType(Self.userFacingName(forFileName: value))
        case .invalidFilename(let value): FileError.invalidFilename(Self.userFacingName(forFileName: value))
        case .filenameExists(let value): FileError.filenameExists(Self.userFacingName(forFileName: value))
        case .missing(let value): FileError.missing(Self.userFacingName(forFileName: value))
        default: artifactError
        }
        return presentedError.localizedDescription
    }
    public var kind: Kind {
        if contentType.conforms(to: .html) { return .html }
        if contentType.conforms(to: .image) { return .image }
        if contentType.conforms(to: .pdf) { return .pdf }
        if contentType.conforms(to: .text) || contentType.conforms(to: .sourceCode)
            || contentType.conforms(to: .json) || contentType.conforms(to: .commaSeparatedText) { return .text }
        return .file
    }
    public var exists: Bool { availability != .unavailable && resourceValues?.isRegularFile == true }
    public var size: Int? { listedSize ?? resourceValues?.fileSize }
    public var createdAt: Date? { listedCreatedAt ?? resourceValues?.creationDate }
    public var modifiedAt: Date? { listedModifiedAt ?? resourceValues?.contentModificationDate }

    init(
        fileName: String,
        directory: URL,
        relativePath: String? = nil,
        availability: Availability = .local,
        size: Int? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil
    ) {
        self.fileName = fileName
        fileURL = directory.appendingPathComponent(relativePath ?? fileName, isDirectory: false)
        self.availability = availability
        listedSize = size
        listedCreatedAt = createdAt
        listedModifiedAt = modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let scope = decoder.userInfo[.profileScope] as? ProfileScope ?? StorageRoot.currentScope
        guard let directory = scope?.root.appendingPathComponent("artifacts", isDirectory: true) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileName = try decoder.singleValueContainer().decode(String.self)
        let listing = decoder.userInfo[.artifactDirectoryListing] as? FileDirectoryListing ?? FileDirectoryListing()
        if let files = listing.files {
            self = files[fileName] ?? files[fileName.lowercased()] ?? FileItem(fileName: fileName, directory: directory, availability: .unavailable)
        } else {
            self = try FileStore.artifact(named: fileName, in: directory, listing: listing)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(fileName)
    }

    private var contentType: UTType {
        return UTType(filenameExtension: fileURL.pathExtension) ?? .data
    }


    private var resourceValues: URLResourceValues? {
        try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ])
    }
}

nonisolated struct FileMetadata: Codable, Sendable {
    let id: UUID
    let fileName: String
    let displayName: String
    let mimeType: String
    let kind: FileItem.Kind
}

nonisolated struct MarkdownFileDocument: Equatable, Sendable {
    let source: String
    let byteCount: Int

    static func read(_ artifact: FileItem) throws -> Self {
        guard artifact.isMarkdown else { throw FileError.unsupportedType(artifact.fileName) }
        guard artifact.exists else { throw FileError.missing(artifact.fileName) }
        let data = try Data(contentsOf: artifact.fileURL)
        guard data.count <= FileLimits.textBytes else {
            throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
        }
        guard let source = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
        return Self(source: source, byteCount: data.count)
    }

    static func write(_ source: String, to artifact: FileItem) throws -> Self {
        guard artifact.isMarkdown else { throw FileError.unsupportedType(artifact.fileName) }
        guard artifact.exists else { throw FileError.missing(artifact.fileName) }
        let data = Data(source.utf8)
        guard data.count <= FileLimits.textBytes else {
            throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
        }
        try data.write(to: artifact.fileURL, options: .atomic)
        return Self(source: source, byteCount: data.count)
    }
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

extension ProfileRepository {
    nonisolated struct DurableProfileFile: Codable, Sendable {
        let path: String
        let size: Int
        let mtime: Double
        let binary: Bool
        let saved: Bool
        let sha256: String?
        let reference: String?
        let aliases: [String]?
    }

    nonisolated private struct DurableFileRecord: Codable, Sendable {
        let path: String
        let size: Int
        let sha256: String
        let binary: Bool
        let saved: Bool
        let reference: String?
        let hidden: Bool?
        let aliases: [String]?

        func artifact(in scope: ProfileScope) -> FileItem {
            FileItem(fileName: reference ?? path.split(separator: "/").last.map(String.init) ?? path,
                     directory: scope.root, relativePath: path, size: size)
        }
    }

    func profileFiles(prefix: String, in scope: ProfileScope) async throws -> [DurableProfileFile] {
        let result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileList"), "prefix": .string(prefix),
        ]))
        guard let values = result.objectValue?["files"]?.arrayValue, values.count <= 10_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let files = try JSONDecoder().decode([DurableProfileFile].self, from: JSONEncoder().encode(JSONValue.array(values)))
        guard Set(files.map(\.path)).count == files.count,
              files.allSatisfy({ $0.path.hasPrefix(prefix) && $0.size >= 0 && $0.size <= FileLimits.fileBytes && $0.mtime.isFinite && $0.mtime >= 0 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return files
    }

    func removeProfileFile(path: String, in scope: ProfileScope) async throws {
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileRemove"), "path": .string(path),
        ]))
    }

    func artifactListing(in scope: ProfileScope) async throws -> FileDirectoryListing {
        var references: [String: FileItem] = [:]
        for file in try await profileFiles(prefix: "", in: scope) {
            guard let name = file.reference else { continue }
            let artifact = FileItem(fileName: name, directory: scope.root, relativePath: file.path, size: file.size,
                modifiedAt: Date(timeIntervalSince1970: file.mtime / 1000))
            references[name] = artifact
            for alias in file.aliases ?? [] { references[alias] = artifact }
        }
        return FileDirectoryListing(files: references)
    }

    func artifacts(in scope: ProfileScope) async throws -> [FileItem] {
        let files = try await profileFiles(prefix: "", in: scope).filter { $0.reference != nil }
        return try files.map { file in
            guard let name = file.reference, try profileFileName(name) == name,
                  file.sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CocoaError(.fileReadCorruptFile) }
            return FileItem(fileName: name, directory: scope.root, relativePath: file.path, size: file.size,
                            modifiedAt: Date(timeIntervalSince1970: file.mtime / 1000))
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func materializeFile(_ artifact: FileItem, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: artifact.fileName, in: scope)
        let expectedURL = scope.root.appendingPathComponent(record.path)
        let legacyURL = scope.root.appendingPathComponent("artifacts").appendingPathComponent(artifact.fileName)
        guard [expectedURL.standardizedFileURL, legacyURL.standardizedFileURL].contains(artifact.fileURL.standardizedFileURL) else { throw CocoaError(.fileReadNoPermission) }
        return try await self.artifact(named: artifact.fileName, in: scope)
    }

    func artifact(named name: String, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: name, in: scope)
        _ = try await readFileBytes(record, in: scope)
        return record.artifact(in: scope)
    }

    func savedFileNames(in scope: ProfileScope) async throws -> Set<String> {
        Set(try await profileFiles(prefix: "", in: scope).filter(\.saved).compactMap(\.reference))
    }

    func setFileSaved(_ saved: Bool, named name: String, in scope: ProfileScope) async throws {
        let record = try await requiredFileRecord(named: name, in: scope)
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileSaved"), "path": .string(record.reference ?? record.path), "saved": .bool(saved),
        ]))
        Log.app.info("ProfileRepository.artifact profile=\(scope.profileID?.uuidString ?? "temporary") saved=\(saved) file=\(name)")
    }

    func importFile(data: Data, suggestedName: String, in scope: ProfileScope, conversation: DurableConversationReference? = nil) async throws -> FileItem {
        if let conversation {
            guard conversation.profileID == scope.profileID else { throw CocoaError(.fileReadNoPermission) }
            let folder = "conversations/\(conversation.conversationID)"
            let cleaned = FileStore.sanitizedFilename(suggestedName)
            let files = try await profileFiles(prefix: folder + "/", in: scope)
            let name = files.contains(where: { $0.path.caseInsensitiveCompare(folder + "/" + cleaned) == .orderedSame }) ? versionedFileName(cleaned) : cleaned
            return try await writeFile(data: data, named: name, in: scope, conversation: conversation)
        }
        let name = try await availableFileName(suggestedName, in: scope)
        return try await writeFile(data: data, named: name, in: scope)
    }

    func writeFile(data: Data, named name: String, in scope: ProfileScope, conversation: DurableConversationReference? = nil) async throws -> FileItem {
        let name = try profileFileName(name)
        guard data.count <= FileLimits.fileBytes else {
            throw FileError.fileTooLarge(bytes: data.count, limit: FileLimits.fileBytes)
        }
        let artifact = FileItem(fileName: name, directory: scope.root.appendingPathComponent("artifacts", isDirectory: true))
        let text: String?
        if artifact.kind == .text || artifact.kind == .html {
            guard data.count <= FileLimits.textBytes else {
                throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
            }
            guard let decoded = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
            text = decoded
        } else {
            text = nil
        }
        let path: String
        if let conversation {
            guard conversation.profileID == scope.profileID else { throw CocoaError(.fileReadNoPermission) }
            path = "conversations/\(conversation.conversationID)/" + name
        } else {
            path = try await artifactRecord(named: name, in: scope)?.path ?? "imports/" + name
        }
        var request: [String: JSONValue] = ["path": .string(path)]
        if let text {
            request["action"] = .string("fileWrite")
            request["text"] = .string(text)
        } else {
            request["action"] = .string("fileWriteBinary")
            request["base64"] = .string(data.base64EncodedString())
        }
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object(request))
        let published = try await self.artifact(named: path, in: scope)
        Log.app.info("ProfileRepository.artifact publish profile=\(scope.profileID?.uuidString ?? "temporary") file=\(name) bytes=\(data.count) binary=\(text == nil)")
        return published
    }

    func replaceFileText(named name: String, oldText: String, newText: String, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: name, in: scope)
        let source = try artifactText(try await readFileBytes(record, in: scope))
        let updated: String
        if oldText.isEmpty {
            updated = source + newText
        } else {
            let matches = ExactTextReplacement.count(oldText, in: source)
            guard matches > 0 else { throw FileError.textNotFound }
            guard matches == 1 else { throw FileError.textAmbiguous(matches: matches) }
            updated = ExactTextReplacement.replace(oldText, with: newText, in: source)
        }
        return try await publishFileVersion(updated, of: record, in: scope)
    }

    func readMarkdownFile(named name: String, in scope: ProfileScope) async throws -> MarkdownFileDocument {
        let record = try await requiredFileRecord(named: name, in: scope)
        guard record.artifact(in: scope).isMarkdown else { throw FileError.unsupportedType(name) }
        let bytes = try await readFileBytes(record, in: scope)
        return MarkdownFileDocument(source: try artifactText(bytes), byteCount: bytes.count)
    }

    func writeMarkdownFile(_ source: String, named name: String, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: name, in: scope)
        guard record.artifact(in: scope).isMarkdown else { throw FileError.unsupportedType(name) }
        return try await publishFileVersion(source, of: record, in: scope)
    }

    func renameFile(named name: String, to newName: String, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: name, in: scope)
        let destination = try profileFileName(newName)
        let source = record.artifact(in: scope)
        if destination == source.fileURL.lastPathComponent { return try await artifact(named: name, in: scope) }
        let relative = (record.path.split(separator: "/").dropLast().map(String.init) + [destination]).joined(separator: "/")
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileMove"), "path": .string(record.path), "prefix": .string(relative),
        ]))
        Log.app.info("ProfileRepository.artifact move profile=\(scope.profileID?.uuidString ?? "temporary") from=\(record.path) to=\(relative)")
        return try await artifact(named: relative, in: scope)
    }

    func deleteFile(named name: String, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: name, in: scope)
        try await removeProfileFile(path: record.reference ?? record.path, in: scope)
        Log.app.info("ProfileRepository.artifact remove profile=\(scope.profileID?.uuidString ?? "temporary") file=\(name) physicalBytesRemoved=true")
        return record.artifact(in: scope)
    }

    private func artifactRecord(named name: String, in scope: ProfileScope) async throws -> DurableFileRecord? {
        let path = name.contains("/") ? name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : try profileFileName(name)
        let result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileStat"), "path": .string(path), "byPath": .bool(name.contains("/")),
        ]))
        guard let value = result.objectValue?["file"] else { throw CocoaError(.fileReadCorruptFile) }
        if value == .null { return nil }
        let record = try JSONDecoder().decode(DurableFileRecord.self, from: JSONEncoder().encode(value))
        guard record.hidden != true, record.path == path || record.reference == path || record.aliases?.contains(path) == true, record.size >= 0, record.size <= (record.binary ? FileLimits.fileBytes : FileLimits.textBytes),
              record.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    private func requiredFileRecord(named name: String, in scope: ProfileScope) async throws -> DurableFileRecord {
        guard let record = try await artifactRecord(named: name, in: scope) else { throw FileError.missing(name) }
        return record
    }

    func readFileData(named name: String, in scope: ProfileScope) async throws -> Data {
        let record = try await requiredFileRecord(named: name, in: scope)
        return try await readFileBytes(record, in: scope)
    }

    private func readFileBytes(_ record: DurableFileRecord, in scope: ProfileScope) async throws -> Data {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
        let bytes = try await DurableProfileStore.shared.readFile(scope: scope, file: value)
        guard bytes.count == record.size else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }

    private func artifactText(_ data: Data) throws -> String {
        guard data.count <= FileLimits.textBytes else {
            throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
        return text
    }

    private func publishFileVersion(_ text: String, of record: DurableFileRecord, in scope: ProfileScope) async throws -> FileItem {
        let data = Data(text.utf8)
        _ = try artifactText(data)
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileWrite"), "path": .string(record.path), "text": .string(text),
        ]))
        return try await artifact(named: record.artifact(in: scope).fileName, in: scope)
    }

    private func availableFileName(_ suggested: String, in scope: ProfileScope) async throws -> String {
        let cleaned = FileStore.sanitizedFilename(suggested.replacingOccurrences(of: "\\", with: " "))
        let files = try await profileFiles(prefix: "imports/", in: scope)
        let visibleCollision = files.contains { $0.path.caseInsensitiveCompare("imports/" + cleaned) == .orderedSame }
        if !visibleCollision, !cleaned.hasPrefix("."), cleaned.utf8.count <= 240,
           try await artifactRecord(named: cleaned, in: scope) == nil { return cleaned }
        return versionedFileName(cleaned)
    }

    private func profileFileName(_ name: String) throws -> String {
        let normalized = try FileStore.validatedFilename(name)
        guard !normalized.hasPrefix("."), !normalized.contains("\\"), normalized.utf8.count <= 240 else {
            throw FileError.invalidFilename(name)
        }
        return normalized
    }

    private func versionedFileName(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        var ext = String(url.pathExtension.prefix(32))
        while ext.utf8.count > 64 { ext.removeLast() }
        var stem = String(url.deletingPathExtension().lastPathComponent.prefix(80))
        while stem.utf8.count > 100 { stem.removeLast() }
        if stem.hasPrefix(".") { stem = "File" }
        let version = "\(stem)-\(UUID().uuidString)"
        return ext.isEmpty ? version : "\(version).\(ext)"
    }
}

nonisolated public enum FileError: LocalizedError {
    case unsupportedType(String)
    case invalidFilename(String)
    case filenameExists(String)
    case missing(String)
    case textNotFound
    case textAmbiguous(matches: Int)
    case textNotUTF8
    case textTooLarge(bytes: Int, limit: Int)
    case invalidPDF
    case encryptedPDF
    case pdfTooLarge(bytes: Int, limit: Int)
    case fileTooLarge(bytes: Int, limit: Int)
    case imageDecodeFailed
    case imageEncodeFailed
    case downloadTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let type): return String(format: L10n.string("Unsupported file type: %@", comment: ""), type)
        case .invalidFilename(let name): return String(format: L10n.string("Invalid filename: %@", comment: ""), name)
        case .filenameExists(let name): return String(format: L10n.string("A file named %@ already exists.", comment: ""), name)
        case .missing(let name): return String(format: L10n.string("Deleted file: %@", comment: ""), name)
        case .textNotFound: return L10n.string("The text to replace wasn't found.", comment: "")
        case .textAmbiguous(let matches): return String(format: L10n.string("The text to replace matched %lld locations; make it more specific.", comment: ""), matches)
        case .textNotUTF8: return L10n.string("Text file isn't UTF-8.", comment: "")
        case .textTooLarge(let bytes, let limit): return String(format: L10n.string("Text file too large (%lld bytes; limit %lld).", comment: ""), bytes, limit)
        case .invalidPDF: return L10n.string("Couldn't read the PDF.", comment: "")
        case .encryptedPDF: return L10n.string("Encrypted PDFs aren't supported.", comment: "")
        case .pdfTooLarge(let bytes, let limit): return String(format: L10n.string("PDF too large (%lld bytes; limit %lld).", comment: ""), bytes, limit)
        case .fileTooLarge(let bytes, let limit): return String(format: L10n.string("File too large (%lld bytes; limit %lld).", comment: ""), bytes, limit)
        case .imageDecodeFailed: return L10n.string("Couldn't decode the image.", comment: "")
        case .imageEncodeFailed: return L10n.string("Couldn't encode the image.", comment: "")
        case .downloadTimedOut(let name): return String(format: L10n.string("Timed out downloading %@ from iCloud.", comment: ""), name)
        }
    }
}

nonisolated public enum FileLimits {
    public static let textBytes = 200 * 1024
    public static let pdfBytes = 32 * 1024 * 1024
    public static let fileBytes = 32 * 1024 * 1024
    public static let imagePixels = 40_000_000
    public static let imageMaxDimension: CGFloat = 1568
    public static let imageJPEGQuality: CGFloat = 0.85
}

nonisolated struct PreparedImage: Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String

    func filename(from suggestedName: String?) -> String {
        let suggested = FileStore.sanitizedFilename(suggestedName ?? "Image")
        let stem = URL(fileURLWithPath: suggested).deletingPathExtension().lastPathComponent
        return "\(stem).\(fileExtension)"
    }
}

nonisolated struct PreparedPDF: Sendable {
    let data: Data
    let pageCount: Int
    let mimeType = "application/pdf"
}

nonisolated enum PDFPreparationError: Error {
    case invalid
    case encrypted
    case tooLarge
}

nonisolated enum PDFPreparer {
    static func prepare(_ data: Data) throws -> PreparedPDF {
        guard data.count <= FileLimits.pdfBytes else { throw PDFPreparationError.tooLarge }
        guard data.starts(with: Data("%PDF-".utf8)),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { throw PDFPreparationError.invalid }
        guard !document.isEncrypted else { throw PDFPreparationError.encrypted }
        return PreparedPDF(data: data, pageCount: document.numberOfPages)
    }

    static func prepareFile(_ data: Data) throws -> PreparedPDF {
        do {
            return try prepare(data)
        } catch PDFPreparationError.tooLarge {
            throw FileError.pdfTooLarge(bytes: data.count, limit: FileLimits.pdfBytes)
        } catch PDFPreparationError.encrypted {
            throw FileError.encryptedPDF
        } catch {
            throw FileError.invalidPDF
        }
    }
}

nonisolated enum ImagePreparationError: Error {
    case invalid
    case tooLarge
    case encode
}

nonisolated enum ImagePreparer {
    struct Inspection {
        let mimeType: String
        let type: UTType
        let width: Int
        let height: Int
    }

    static func inspect(_ data: Data) throws -> Inspection {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              [.jpeg, .png, .gif, .webP, .heic, .heif].contains(where: { type.conforms(to: $0) }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImagePreparationError.invalid }
        guard width <= FileLimits.imagePixels / height else { throw ImagePreparationError.tooLarge }
        return Inspection(
            mimeType: type.preferredMIMEType ?? "image/unknown",
            type: type,
            width: width,
            height: height
        )
    }

    static func prepare(_ data: Data) throws -> PreparedImage {
        let inspection = try inspect(data)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw ImagePreparationError.invalid
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(FileLimits.imageMaxDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImagePreparationError.invalid
        }
        let lossless = inspection.type.conforms(to: .png)
            || inspection.type.conforms(to: .gif)
            || hasAlpha(image)
        #if os(iOS)
        return try encode(UIImage(cgImage: image), lossless: lossless)
        #else
        let data = NSMutableData()
        let type = lossless ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImagePreparationError.encode
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: FileLimits.imageJPEGQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagePreparationError.encode }
        return PreparedImage(data: data as Data, mimeType: lossless ? "image/png" : "image/jpeg", fileExtension: lossless ? "png" : "jpg")
        #endif
    }

    static func preparePreservingResolution(_ data: Data) throws -> PreparedImage {
        let inspection = try inspect(data)
        if inspection.type.conforms(to: .png) {
            return PreparedImage(data: data, mimeType: "image/png", fileExtension: "png")
        }
        if inspection.type.conforms(to: .jpeg) {
            return PreparedImage(data: data, mimeType: "image/jpeg", fileExtension: "jpg")
        }
        throw ImagePreparationError.invalid
    }

    #if os(iOS)
    static func prepare(_ image: UIImage, suggestedName: String?) throws -> PreparedImage {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard width > 0, height > 0 else { throw ImagePreparationError.invalid }
        let lossless = URL(fileURLWithPath: suggestedName ?? "").pathExtension.lowercased() == "png"
            || image.cgImage.map(hasAlpha) == true
        let longest = max(width, height)
        let scale = min(1, FileLimits.imageMaxDimension / CGFloat(max(1, longest)))
        let target = CGSize(width: max(1, CGFloat(width) * scale), height: max(1, CGFloat(height) * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !lossless
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return try encode(rendered, lossless: lossless)
    }

    private static func encode(_ image: UIImage, lossless: Bool) throws -> PreparedImage {
        if lossless {
            guard let data = image.pngData() else { throw ImagePreparationError.encode }
            return PreparedImage(data: data, mimeType: "image/png", fileExtension: "png")
        }
        guard let data = image.jpegData(compressionQuality: FileLimits.imageJPEGQuality) else {
            throw ImagePreparationError.encode
        }
        return PreparedImage(data: data, mimeType: "image/jpeg", fileExtension: "jpg")
    }

    #endif

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast: true
        case .none, .noneSkipFirst, .noneSkipLast: false
        @unknown default: true
        }
    }
}

nonisolated public enum FileImporter {
    private struct Draft: Sendable {
        let data: Data
        let fileName: String
    }

    #if os(iOS)
    public static func importImageAsync(_ image: UIImage, suggestedName: String?) async throws -> FileItem {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        return try await importImageAsync(image, suggestedName: suggestedName, in: scope)
    }

    static func importImageAsync(
        _ image: UIImage,
        suggestedName: String?,
        in scope: ProfileScope
    ) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try imageDraft(image, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope)
    }

    #endif

    public static func importImageDataAsync(_ data: Data, suggestedName: String?) async throws -> FileItem {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        return try await importImageDataAsync(data, suggestedName: suggestedName, in: scope)
    }

    static func importImageDataAsync(
        _ data: Data,
        suggestedName: String?,
        in scope: ProfileScope
    ) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try imageDataDraft(data, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope)
    }

    public static func importFileAsync(at url: URL) async throws -> FileItem {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        return try await importFileAsync(at: url, in: scope)
    }

    static func importFileAsync(at url: URL, in scope: ProfileScope) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try fileDraft(at: url)
        }.value
        return try await write(draft, in: scope)
    }

    static func importDataAsync(_ data: Data, suggestedName: String, in scope: ProfileScope, conversation: DurableConversationReference? = nil) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try dataDraft(data, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope, conversation: conversation)
    }

    static func importPreparedImageDataAsync(
        _ data: Data,
        suggestedName: String,
        in scope: ProfileScope
    ) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try preparedImageDataDraft(data, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope)
    }

    #if os(iOS)
    private static func imageDraft(_ image: UIImage, suggestedName: String?) throws -> Draft {
        do {
            let prepared = try ImagePreparer.prepare(image, suggestedName: suggestedName)
            return Draft(data: prepared.data, fileName: prepared.filename(from: suggestedName))
        } catch ImagePreparationError.encode {
            throw FileError.imageEncodeFailed
        } catch {
            throw FileError.imageDecodeFailed
        }
    }

    #endif

    private static func imageDataDraft(_ data: Data, suggestedName: String?) throws -> Draft {
        do {
            let prepared = try ImagePreparer.prepare(data)
            return Draft(data: prepared.data, fileName: prepared.filename(from: suggestedName))
        } catch ImagePreparationError.encode {
            throw FileError.imageEncodeFailed
        } catch {
            throw FileError.imageDecodeFailed
        }
    }

    private static func preparedImageDataDraft(_ data: Data, suggestedName: String?) throws -> Draft {
        guard data.count <= FileLimits.fileBytes else {
            throw FileError.fileTooLarge(bytes: data.count, limit: FileLimits.fileBytes)
        }
        do {
            let prepared = try ImagePreparer.preparePreservingResolution(data)
            return Draft(data: prepared.data, fileName: prepared.filename(from: suggestedName))
        } catch {
            throw FileError.imageDecodeFailed
        }
    }

    private static func fileDraft(at url: URL) throws -> Draft {
        let data = try Data(contentsOf: url)
        return try dataDraft(data, suggestedName: url.lastPathComponent)
    }

    private static func dataDraft(_ data: Data, suggestedName: String) throws -> Draft {
        let fileName = FileStore.sanitizedFilename(suggestedName)
        let type = UTType(filenameExtension: URL(fileURLWithPath: fileName).pathExtension) ?? .data
        if type.conforms(to: .image) {
            return try imageDataDraft(data, suggestedName: fileName)
        }
        if type.conforms(to: .pdf) {
            _ = try PDFPreparer.prepareFile(data)
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .json) || type.conforms(to: .commaSeparatedText) {
            guard data.count <= FileLimits.textBytes else {
                throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
            }
            guard String(data: data, encoding: .utf8) != nil else { throw FileError.textNotUTF8 }
        } else if data.count > FileLimits.fileBytes {
            throw FileError.fileTooLarge(bytes: data.count, limit: FileLimits.fileBytes)
        }
        return Draft(data: data, fileName: fileName)
    }

    private static func write(_ draft: Draft, in scope: ProfileScope, conversation: DurableConversationReference? = nil) async throws -> FileItem {
        try await ProfileRepository.shared.importFile(data: draft.data, suggestedName: draft.fileName, in: scope, conversation: conversation)
    }

}

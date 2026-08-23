import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated extension CodingUserInfoKey {
    static let profileScope = CodingUserInfoKey(rawValue: "profileScope")!
}

nonisolated public struct Artifact: Equatable, Sendable, Identifiable, Codable {
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
    public var displayName: String { fileName }
    public var userFacingName: String {
        hidesImplementation ? Self.userFacingName(forFileName: fileName) : displayName
    }
    public var userFacingTypeName: String? {
        if kind == .html { return L10n.string("Canvas") }
        if isMarkdown { return L10n.string("Note") }
        return nil
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
    public func fileName(forUserFacingName name: String) -> String {
        guard hidesImplementation else { return name }
        let fileExtension = fileURL.pathExtension
        if URL(fileURLWithPath: name).pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame {
            return name
        }
        return "\(name).\(fileExtension)"
    }
    func updatingAvailability(_ availability: Availability) -> Artifact {
        Artifact(
            fileName: fileName,
            directory: fileURL.deletingLastPathComponent(),
            availability: availability,
            size: listedSize,
            createdAt: listedCreatedAt,
            modifiedAt: listedModifiedAt
        )
    }
    public static func userFacingName(forFileName fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        switch url.pathExtension.lowercased() {
        case "htm", "html", "md", "markdown": return url.deletingPathExtension().lastPathComponent
        default: return fileName
        }
    }
    public func userFacingErrorDescription(_ error: Error) -> String {
        guard let artifactError = error as? ArtifactError else { return error.localizedDescription }
        let presentedError = switch artifactError {
        case .unsupportedType(let value): ArtifactError.unsupportedType(Self.userFacingName(forFileName: value))
        case .invalidFilename(let value): ArtifactError.invalidFilename(Self.userFacingName(forFileName: value))
        case .filenameExists(let value): ArtifactError.filenameExists(Self.userFacingName(forFileName: value))
        case .missing(let value): ArtifactError.missing(Self.userFacingName(forFileName: value))
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
    public var exists: Bool { resourceValues?.isRegularFile == true }
    public var size: Int? { listedSize ?? resourceValues?.fileSize }
    public var createdAt: Date? { listedCreatedAt ?? resourceValues?.creationDate }
    public var modifiedAt: Date? { listedModifiedAt ?? resourceValues?.contentModificationDate }

    init(
        fileName: String,
        directory: URL,
        availability: Availability = .local,
        size: Int? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil
    ) {
        self.fileName = fileName
        fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
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
        self = try ArtifactStore.artifact(named: fileName, in: directory)
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(fileName)
    }

    private var contentType: UTType {
        return UTType(filenameExtension: fileURL.pathExtension) ?? .data
    }

    private var hidesImplementation: Bool { kind == .html || isMarkdown }

    private var resourceValues: URLResourceValues? {
        try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ])
    }
}

nonisolated struct ArtifactMetadata: Codable, Sendable {
    let id: UUID
    let fileName: String
    let displayName: String
    let mimeType: String
    let kind: Artifact.Kind
}

nonisolated struct MarkdownArtifactDocument: Equatable, Sendable {
    let source: String
    let byteCount: Int

    static func read(_ artifact: Artifact) throws -> Self {
        guard artifact.isMarkdown else { throw ArtifactError.unsupportedType(artifact.fileName) }
        guard artifact.exists else { throw ArtifactError.missing(artifact.fileName) }
        let data = try Data(contentsOf: artifact.fileURL)
        guard data.count <= ArtifactLimits.textBytes else {
            throw ArtifactError.textTooLarge(bytes: data.count, limit: ArtifactLimits.textBytes)
        }
        guard let source = String(data: data, encoding: .utf8) else { throw ArtifactError.textNotUTF8 }
        return Self(source: source, byteCount: data.count)
    }

    static func write(_ source: String, to artifact: Artifact) throws -> Self {
        guard artifact.isMarkdown else { throw ArtifactError.unsupportedType(artifact.fileName) }
        guard artifact.exists else { throw ArtifactError.missing(artifact.fileName) }
        let data = Data(source.utf8)
        guard data.count <= ArtifactLimits.textBytes else {
            throw ArtifactError.textTooLarge(bytes: data.count, limit: ArtifactLimits.textBytes)
        }
        try data.write(to: artifact.fileURL, options: .atomic)
        return Self(source: source, byteCount: data.count)
    }
}

@MainActor
private final class UbiquitousArtifactQuery {
    private let directory: URL
    private let query = NSMetadataQuery()
    private var continuation: CheckedContinuation<[Artifact], Never>?
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    static func run(in directory: URL) async -> [Artifact] {
        await UbiquitousArtifactQuery(directory: directory).run()
    }

    private func run() async -> [Artifact] {
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
        let artifacts = query.results.compactMap { result -> Artifact? in
            guard let item = result as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.deletingLastPathComponent().standardizedFileURL == directory,
                  !url.lastPathComponent.starts(with: ".") else { return nil }
            let typeTree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
            guard !typeTree.contains("public.folder") else { return nil }
            let error = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingErrorKey) as? Error
            let isDownloading = item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool ?? false
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let availability: Artifact.Availability
            if error != nil {
                availability = .unavailable
            } else if isDownloading {
                availability = .downloading
            } else if status == URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue {
                availability = .cloudOnly
            } else {
                availability = .local
            }
            return Artifact(
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

nonisolated enum ArtifactStore {
    static let metadataName = "artifact.json"
    private static let savedIndexName = ".saved.json"

    static func artifact(named name: String, in directory: URL) throws -> Artifact {
        let requested = try validatedFilename(name)
        let resolved = existingFilename(matching: requested, in: directory) ?? requested
        return Artifact(fileName: resolved, directory: directory)
    }

    static func importLegacy(_ metadata: ArtifactMetadata, source: URL, into directory: URL) throws {
        let folder = directory.appendingPathComponent(metadata.id.uuidString, isDirectory: true)
        let metadataURL = folder.appendingPathComponent(metadataName, isDirectory: false)
        if FileManager.default.fileExists(atPath: metadataURL.path) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(metadata.fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }

    static func list(in directory: URL) -> [Artifact] {
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

    static func listIncludingUbiquitousItems(in directory: URL) async -> [Artifact] {
        let local = list(in: directory)
        let ubiquitous = await UbiquitousArtifactQuery.run(in: directory)
        var merged = Dictionary(uniqueKeysWithValues: ubiquitous.map { ($0.fileName.lowercased(), $0) })
        for artifact in local {
            merged[artifact.fileName.lowercased()] = artifact
        }
        return merged.values.sorted {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    private static func artifact(at file: URL, in directory: URL) -> Artifact? {
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
        let availability: Artifact.Availability
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
        let resolvedAvailability: Artifact.Availability = SimEnv.cloudOnlyArtifacts.contains(file.lastPathComponent)
            ? .cloudOnly
            : availability
        #else
        let resolvedAvailability = availability
        #endif
        return Artifact(
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
            Log.app.error("ArtifactStore.savedNames failed=\(error.localizedDescription)")
            return []
        }
    }

    static func setSaved(_ saved: Bool, name: String, directory: URL) throws {
        let artifact = try requiredArtifact(named: name, in: directory)
        var names = savedNames(in: directory)
        names = Set(names.filter { $0.caseInsensitiveCompare(artifact.fileName) != .orderedSame })
        if saved { names.insert(artifact.fileName) }
        try writeSavedNames(names, in: directory)
    }

    static func writeImported(data: Data, suggestedName: String, directory: URL) throws -> Artifact {
        let fileName = uniqueFilename(suggestedName, in: directory)
        let artifact = Artifact(fileName: fileName, directory: directory)
        try data.write(to: artifact.fileURL, options: .atomic)
        return artifact
    }

    static func write(data: Data, named name: String, directory: URL) throws -> Artifact {
        let requested = try validatedFilename(name)
        let fileName = existingFilename(matching: requested, in: directory) ?? requested
        let artifact = Artifact(fileName: fileName, directory: directory)
        try data.write(to: artifact.fileURL, options: .atomic)
        return artifact
    }

    static func edit(name: String, find: String, replace: String, directory: URL) throws -> Artifact {
        let artifact = try requiredArtifact(named: name, in: directory)
        let data = try Data(contentsOf: artifact.fileURL)
        guard data.count <= ArtifactLimits.textBytes else {
            throw ArtifactError.textTooLarge(bytes: data.count, limit: ArtifactLimits.textBytes)
        }
        guard let current = String(data: data, encoding: .utf8) else { throw ArtifactError.textNotUTF8 }
        let updated: String
        if find.isEmpty {
            updated = current + replace
        } else {
            let matches = ExactTextReplacement.count(find, in: current)
            guard matches > 0 else { throw ArtifactError.textNotFound }
            guard matches == 1 else { throw ArtifactError.textAmbiguous(matches: matches) }
            updated = ExactTextReplacement.replace(find, with: replace, in: current)
        }
        let updatedData = Data(updated.utf8)
        guard updatedData.count <= ArtifactLimits.textBytes else {
            throw ArtifactError.textTooLarge(bytes: updatedData.count, limit: ArtifactLimits.textBytes)
        }
        try updatedData.write(to: artifact.fileURL, options: .atomic)
        return artifact
    }

    static func rename(_ name: String, to newName: String, directory: URL) throws -> Artifact {
        let source = try requiredArtifact(named: name, in: directory)
        let requested = try validatedFilename(newName)
        if source.fileName == requested { return source }
        if let collision = existingFilename(matching: requested, in: directory), collision != source.fileName {
            throw ArtifactError.filenameExists(collision)
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
        return Artifact(fileName: requested, directory: directory)
    }

    static func remove(_ name: String, directory: URL) throws -> Artifact {
        let artifact = try requiredArtifact(named: name, in: directory)
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
        if value.isEmpty || value == "." || value == ".." { value = "Artifact" }
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
            throw ArtifactError.invalidFilename(name)
        }
        return normalized
    }

    static func existingFilename(matching name: String, in directory: URL) -> String? {
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names?.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func requiredArtifact(named name: String, in directory: URL) throws -> Artifact {
        let requested = try validatedFilename(name)
        guard let existing = existingFilename(matching: requested, in: directory) else {
            throw ArtifactError.missing(requested)
        }
        let artifact = Artifact(fileName: existing, directory: directory)
        guard artifact.exists else { throw ArtifactError.missing(requested) }
        return artifact
    }
}

extension ProfileRepository {
    func artifacts(in scope: ProfileScope) async -> [Artifact] {
        guard let directory = try? artifactsDirectory(in: scope) else { return [] }
        if scope.location == .iCloud {
            return await ArtifactStore.listIncludingUbiquitousItems(in: directory)
        }
        return ArtifactStore.list(in: directory)
    }

    func materializeArtifact(_ artifact: Artifact, in scope: ProfileScope) async throws -> Artifact {
        guard artifact.availability != .local else { return artifact }
        let url = try artifactsDirectory(in: scope).appendingPathComponent(artifact.fileName, isDirectory: false)
        Log.app.info("ProfileRepository.artifact download-start file=\(artifact.fileName) availability=\(artifact.availability.rawValue)")
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemDownloadingErrorKey,
            ])
            if let error = values?.ubiquitousItemDownloadingError {
                Log.app.error("ProfileRepository.artifact download-failed file=\(artifact.fileName) error=\(error.localizedDescription)")
                throw error
            }
            if values?.isRegularFile == true, values?.ubiquitousItemDownloadingStatus != .notDownloaded {
                let local = try ArtifactStore.artifact(named: artifact.fileName, in: url.deletingLastPathComponent())
                Log.app.info("ProfileRepository.artifact download-complete file=\(artifact.fileName)")
                return local
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        Log.app.error("ProfileRepository.artifact download-timeout file=\(artifact.fileName)")
        throw ArtifactError.downloadTimedOut(artifact.fileName)
    }

    func artifact(named name: String, in scope: ProfileScope) throws -> Artifact {
        try ArtifactStore.artifact(named: name, in: artifactsDirectory(in: scope))
    }

    func savedArtifactNames(in scope: ProfileScope) -> Set<String> {
        guard let directory = try? artifactsDirectory(in: scope) else { return [] }
        return ArtifactStore.savedNames(in: directory)
    }

    func setArtifactSaved(_ saved: Bool, named name: String, in scope: ProfileScope) throws {
        try ArtifactStore.setSaved(saved, name: name, directory: artifactsDirectory(in: scope))
        Log.app.info("ProfileRepository.artifact saved=\(saved) file=\(name)")
    }

    func importArtifact(data: Data, suggestedName: String, in scope: ProfileScope) throws -> Artifact {
        try ArtifactStore.writeImported(data: data, suggestedName: suggestedName, directory: artifactsDirectory(in: scope))
    }

    func writeArtifact(data: Data, named name: String, in scope: ProfileScope) throws -> Artifact {
        let directory = try artifactsDirectory(in: scope)
        let artifact = try ArtifactStore.artifact(named: name, in: directory)
        return try coordinatedArtifactWrite(at: artifact.fileURL) { url in
            try ArtifactStore.write(
                data: data,
                named: url.lastPathComponent,
                directory: url.deletingLastPathComponent()
            )
        }
    }

    func replaceArtifactText(named name: String, oldText: String, newText: String, in scope: ProfileScope) throws -> Artifact {
        let directory = try artifactsDirectory(in: scope)
        let artifact = try ArtifactStore.artifact(named: name, in: directory)
        return try coordinatedArtifactWrite(at: artifact.fileURL) { url in
            try ArtifactStore.edit(
                name: url.lastPathComponent,
                find: oldText,
                replace: newText,
                directory: url.deletingLastPathComponent()
            )
        }
    }

    func readMarkdownArtifact(named name: String, in scope: ProfileScope) throws -> MarkdownArtifactDocument {
        let directory = try artifactsDirectory(in: scope)
        let artifact = try ArtifactStore.artifact(named: name, in: directory)
        return try coordinatedArtifactRead(at: artifact.fileURL) { url in
            try MarkdownArtifactDocument.read(Artifact(
                fileName: url.lastPathComponent,
                directory: url.deletingLastPathComponent()
            ))
        }
    }

    func writeMarkdownArtifact(_ source: String, named name: String, in scope: ProfileScope) throws -> MarkdownArtifactDocument {
        let directory = try artifactsDirectory(in: scope)
        let artifact = try ArtifactStore.artifact(named: name, in: directory)
        return try coordinatedArtifactWrite(at: artifact.fileURL) { url in
            try MarkdownArtifactDocument.write(source, to: Artifact(
                fileName: url.lastPathComponent,
                directory: url.deletingLastPathComponent()
            ))
        }
    }

    func deleteArtifact(named name: String, in scope: ProfileScope) throws -> Artifact {
        try ArtifactStore.remove(name, directory: artifactsDirectory(in: scope))
    }

    private func coordinatedArtifactRead<T>(at url: URL, read: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try read(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func coordinatedArtifactWrite<T>(at url: URL, write: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try write(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}

nonisolated public enum ArtifactError: LocalizedError {
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
        case .invalidFilename(let name): return String(format: L10n.string("Invalid artifact filename: %@", comment: ""), name)
        case .filenameExists(let name): return String(format: L10n.string("An artifact named %@ already exists.", comment: ""), name)
        case .missing(let name): return String(format: L10n.string("Missing artifact: %@", comment: ""), name)
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

nonisolated public enum ArtifactLimits {
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
        let suggested = ArtifactStore.sanitizedFilename(suggestedName ?? "Image")
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
        guard data.count <= ArtifactLimits.pdfBytes else { throw PDFPreparationError.tooLarge }
        guard data.starts(with: Data("%PDF-".utf8)),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { throw PDFPreparationError.invalid }
        guard !document.isEncrypted else { throw PDFPreparationError.encrypted }
        return PreparedPDF(data: data, pageCount: document.numberOfPages)
    }

    static func prepareArtifact(_ data: Data) throws -> PreparedPDF {
        do {
            return try prepare(data)
        } catch PDFPreparationError.tooLarge {
            throw ArtifactError.pdfTooLarge(bytes: data.count, limit: ArtifactLimits.pdfBytes)
        } catch PDFPreparationError.encrypted {
            throw ArtifactError.encryptedPDF
        } catch {
            throw ArtifactError.invalidPDF
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
        guard width <= ArtifactLimits.imagePixels / height else { throw ImagePreparationError.tooLarge }
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
            kCGImageSourceThumbnailMaxPixelSize: Int(ArtifactLimits.imageMaxDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImagePreparationError.invalid
        }
        let lossless = inspection.type.conforms(to: .png)
            || inspection.type.conforms(to: .gif)
            || hasAlpha(image)
        return try encode(UIImage(cgImage: image), lossless: lossless)
    }

    static func prepare(_ image: UIImage, suggestedName: String?) throws -> PreparedImage {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard width > 0, height > 0 else { throw ImagePreparationError.invalid }
        let lossless = URL(fileURLWithPath: suggestedName ?? "").pathExtension.lowercased() == "png"
            || image.cgImage.map(hasAlpha) == true
        let longest = max(width, height)
        let scale = min(1, ArtifactLimits.imageMaxDimension / CGFloat(max(1, longest)))
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
        guard let data = image.jpegData(compressionQuality: ArtifactLimits.imageJPEGQuality) else {
            throw ImagePreparationError.encode
        }
        return PreparedImage(data: data, mimeType: "image/jpeg", fileExtension: "jpg")
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast: true
        case .none, .noneSkipFirst, .noneSkipLast: false
        @unknown default: true
        }
    }
}

nonisolated public enum ArtifactImporter {
    private struct Draft: Sendable {
        let data: Data
        let fileName: String
    }

    public static func importImageAsync(_ image: UIImage, suggestedName: String?) async throws -> Artifact {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        let draft = try await Task.detached(priority: .userInitiated) {
            try imageDraft(image, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope)
    }

    public static func importImageDataAsync(_ data: Data, suggestedName: String?) async throws -> Artifact {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        let draft = try await Task.detached(priority: .userInitiated) {
            try imageDataDraft(data, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope)
    }

    public static func importFileAsync(at url: URL) async throws -> Artifact {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        let draft = try await Task.detached(priority: .userInitiated) {
            try fileDraft(at: url)
        }.value
        return try await write(draft, in: scope)
    }

    static func importDataAsync(_ data: Data, suggestedName: String, in scope: ProfileScope) async throws -> Artifact {
        let draft = try await Task.detached(priority: .userInitiated) {
            try dataDraft(data, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope)
    }

    private static func imageDraft(_ image: UIImage, suggestedName: String?) throws -> Draft {
        do {
            let prepared = try ImagePreparer.prepare(image, suggestedName: suggestedName)
            return Draft(data: prepared.data, fileName: prepared.filename(from: suggestedName))
        } catch ImagePreparationError.encode {
            throw ArtifactError.imageEncodeFailed
        } catch {
            throw ArtifactError.imageDecodeFailed
        }
    }

    private static func imageDataDraft(_ data: Data, suggestedName: String?) throws -> Draft {
        do {
            let prepared = try ImagePreparer.prepare(data)
            return Draft(data: prepared.data, fileName: prepared.filename(from: suggestedName))
        } catch ImagePreparationError.encode {
            throw ArtifactError.imageEncodeFailed
        } catch {
            throw ArtifactError.imageDecodeFailed
        }
    }

    private static func fileDraft(at url: URL) throws -> Draft {
        let data = try Data(contentsOf: url)
        return try dataDraft(data, suggestedName: url.lastPathComponent)
    }

    private static func dataDraft(_ data: Data, suggestedName: String) throws -> Draft {
        let fileName = ArtifactStore.sanitizedFilename(suggestedName)
        let type = UTType(filenameExtension: URL(fileURLWithPath: fileName).pathExtension) ?? .data
        if type.conforms(to: .image) {
            return try imageDataDraft(data, suggestedName: fileName)
        }
        if type.conforms(to: .pdf) {
            _ = try PDFPreparer.prepareArtifact(data)
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .json) || type.conforms(to: .commaSeparatedText) {
            guard data.count <= ArtifactLimits.textBytes else {
                throw ArtifactError.textTooLarge(bytes: data.count, limit: ArtifactLimits.textBytes)
            }
            guard String(data: data, encoding: .utf8) != nil else { throw ArtifactError.textNotUTF8 }
        } else if data.count > ArtifactLimits.fileBytes {
            throw ArtifactError.fileTooLarge(bytes: data.count, limit: ArtifactLimits.fileBytes)
        }
        return Draft(data: data, fileName: fileName)
    }

    private static func write(_ draft: Draft, in scope: ProfileScope) async throws -> Artifact {
        try await ProfileRepository.shared.importArtifact(data: draft.data, suggestedName: draft.fileName, in: scope)
    }

}

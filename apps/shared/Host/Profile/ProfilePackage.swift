import CryptoKit
import Foundation

nonisolated enum ProfilePackage {
    static let maximumBytes = 128 * 1024 * 1024
    static let maximumEntries = 10_000

    struct Manifest: Codable, Sendable {
        let format: Int
        let profile: ProfileConfig
        let name: String
        let exportedAt: Date
        let directories: [String]
        let checksums: [String: String]
    }

    struct Backup: Sendable {
        let manifest: Manifest
        let files: [ZipArchiveCodec.File]
    }

    enum Failure: LocalizedError {
        case invalid
        case unsupported
        case tooLarge
        case unsafeFile

        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "This isn't a valid Profile backup.")
            case .unsupported: String(localized: "This Profile backup requires a different version of Ox.")
            case .tooLarge: String(localized: "Profile backups must be smaller than 128 MB and contain fewer than 10,000 files.")
            case .unsafeFile: String(localized: "Profile backups cannot contain symbolic links or special files.")
            }
        }
    }

    static func folder(_ data: Data) throws -> FileWrapper {
        let backup = try ProfilePackage.decode(data)
        let folder = FileWrapper(directoryWithFileWrappers: [:])
        for directory in backup.manifest.directories {
            _ = Self.directory(Self.path(directory), in: folder)
        }
        for file in backup.files {
            let parts = Self.path(file.path)
            guard let name = parts.last else { throw ProfilePackage.Failure.invalid }
            let parent = Self.directory(Array(parts.dropLast()), in: folder)
            let entry = FileWrapper(regularFileWithContents: file.data)
            entry.preferredFilename = name
            parent.addFileWrapper(entry)
        }
        var config = backup.manifest.profile
        config.contentDirectory = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = FileWrapper(regularFileWithContents: try encoder.encode(config))
        manifest.preferredFilename = ProfileIO.configName
        folder.addFileWrapper(manifest)
        return folder
    }

    private static func path(_ path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        return (parts.first == "state" ? [".ox"] : []) + parts.dropFirst()
    }

    private static func directory(_ parts: [String], in root: FileWrapper) -> FileWrapper {
        parts.reduce(root) { parent, name in
            if let existing = parent.fileWrappers?[name] { return existing }
            let child = FileWrapper(directoryWithFileWrappers: [:])
            child.preferredFilename = name
            parent.addFileWrapper(child)
            return child
        }
    }

    static func encode(_ profile: Profile, scope: ProfileScope, progress: @Sendable (Double) -> Void = { _ in }) throws -> Data {
        var result: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: scope.root, options: .withoutChanges, error: &coordinationError) { _ in
            result = Result { try capture(profile, scope: scope, progress: progress) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.invalid }
        return try result.get()
    }

    private static func capture(_ profile: Profile, scope: ProfileScope, progress: @Sendable (Double) -> Void) throws -> Data {
        let started = Date()
        guard let config = ProfileIO.readConfig(at: profile.url),
              config.version == ProfileSchema.current else { throw Failure.unsupported }
        let owner = DurableFileStore(root: scope.root, stateRoot: scope.stateRoot)
        try owner.acquire()
        defer { owner.close() }
        var files: [ZipArchiveCodec.File] = []
        var directories: [String] = []
        var total = 0
        for (index, source) in [("content", scope.root), ("state", scope.stateRoot)].enumerated() {
            let (prefix, root) = source
            directories.append(prefix)
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                errorHandler: { _, error in enumerationError = error; return false }) else { throw Failure.invalid }
            var entries: [(URL, String)] = []
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
                let first = relative.split(separator: "/").first.map(String.init) ?? ""
                if prefix == "content", [".ox", "profile.json", "state.sqlite", "payloads", "staging"].contains(first) || first.hasPrefix("state.sqlite-") || first.hasPrefix(".ox-stage-") {
                    enumerator.skipDescendants()
                    continue
                }
                if prefix == "state", relative != "state.sqlite", !relative.hasPrefix("payloads/"), relative != "payloads" {
                    enumerator.skipDescendants()
                    continue
                }
                guard entries.count < maximumEntries else { throw Failure.tooLarge }
                entries.append((url, relative))
            }
            if let enumerationError { throw enumerationError }
            for (entryIndex, entry) in entries.enumerated() {
                let (url, relative) = entry
                try Task.checkCancellation()
                progress(0.2 + 0.5 * (Double(index) + Double(entryIndex + 1) / Double(max(1, entries.count))) / 2)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw Failure.unsafeFile }
                let path = prefix + "/" + relative
                if values.isDirectory == true {
                    directories.append(path)
                } else {
                    guard values.isRegularFile == true else { throw Failure.unsafeFile }
                    let size = values.fileSize ?? maximumBytes
                    guard size <= maximumBytes - total, files.count < maximumEntries - 1 else { throw Failure.tooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= maximumBytes - total else { throw Failure.tooLarge }
                    total += data.count
                    files.append(.init(path: path, data: data))
                }
                guard directories.count <= maximumEntries else { throw Failure.tooLarge }
            }
        }
        guard files.contains(where: { $0.path == "state/state.sqlite" }) else {
            Log.app.error("ProfilePackage.export missingDatabase profile=\(profile.id) files=\(files.count)")
            throw Failure.invalid
        }
        progress(0.7)
        let manifest = Manifest(format: 1, profile: config, name: profile.name, exportedAt: Date(),
            directories: directories.sorted(), checksums: Dictionary(uniqueKeysWithValues: files.map { ($0.path, digest($0.data)) }))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        files.append(.init(path: "manifest.json", data: try encoder.encode(manifest)))
        let data = try ZipArchiveCodec.encode(files, maximumArchiveBytes: maximumBytes) { progress(0.75 + 0.2 * $0) }
        Log.app.info("ProfilePackage.export profile=\(profile.id) files=\(files.count) bytes=\(data.count) seconds=\(Date().timeIntervalSince(started))")
        return data
    }

    static func read(_ url: URL) throws -> Backup {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var result: Result<Backup, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result {
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes + 1
                guard size <= maximumBytes else { throw Failure.tooLarge }
                return try decode(Data(contentsOf: source))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.invalid }
        return try result.get()
    }

    static func decode(_ data: Data) throws -> Backup {
        do { return try validate(data) }
        catch ZipArchiveError.tooLarge { throw Failure.tooLarge }
        catch is ZipArchiveError { throw Failure.invalid }
        catch is DecodingError { throw Failure.invalid }
    }

    private static func validate(_ data: Data) throws -> Backup {
        let files = try ZipArchiveCodec.decode(data, maximumArchiveBytes: maximumBytes,
            maximumEntryBytes: maximumBytes, maximumEntries: maximumEntries, maximumTotalBytes: maximumBytes)
        guard let manifestFile = files.first(where: { $0.path == "manifest.json" }) else { throw Failure.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: manifestFile.data)
        guard manifest.format == 1, manifest.profile.version == ProfileSchema.current else { throw Failure.unsupported }
        let payload = files.filter { $0.path != "manifest.json" }
        guard payload.contains(where: { $0.path == "state/state.sqlite" }), manifest.directories.count <= maximumEntries,
              Set(payload.map(\.path)) == Set(manifest.checksums.keys),
              payload.allSatisfy({ validPath($0.path) && digest($0.data) == manifest.checksums[$0.path] }),
              manifest.directories.allSatisfy(validPath),
              Set(manifest.directories.map { $0.lowercased() }).count == manifest.directories.count else { throw Failure.invalid }
        return Backup(manifest: manifest, files: payload)
    }

    static func stage(_ backup: Backup, content: URL, state: URL) throws {
        for directory in backup.manifest.directories {
            try FileManager.default.createDirectory(at: destination(directory, content: content, state: state), withIntermediateDirectories: true)
        }
        for file in backup.files {
            try Task.checkCancellation()
            let target = destination(file.path, content: content, state: state)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: target, options: .atomic)
        }
    }

    private static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if parts.first == "content" { return true }
        return path == "state" || path == "state/state.sqlite" || path == "state/payloads" || path.hasPrefix("state/payloads/")
    }

    private static func destination(_ path: String, content: URL, state: URL) -> URL {
        let parts = path.split(separator: "/")
        let base = parts.first == "content" ? content : state
        return parts.dropFirst().reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

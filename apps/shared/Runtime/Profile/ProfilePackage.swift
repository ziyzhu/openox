import Foundation

nonisolated enum ProfilePackage {
    static let maximumEntries = 10_000

    enum Failure: LocalizedError {
        case invalid
        case unsupported
        case tooLarge
        case unsafeFile

        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "This isn't a valid Profile backup.")
            case .unsupported: String(localized: "This Profile backup requires a different version of Ox.")
            case .tooLarge: String(localized: "Profile copies must contain fewer than 10,000 files.")
            case .unsafeFile: String(localized: "Profile backups cannot contain symbolic links or special files.")
            }
        }
    }

    static func export(_ profile: Profile, scope: ProfileScope, to destination: URL, progress: @Sendable (Double) -> Void = { _ in }) throws {
        var result: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: scope.root, options: .withoutChanges, error: &coordinationError) { _ in
            result = Result { try copy(profile, scope: scope, to: destination, progress: progress) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.invalid }
        try result.get()
    }

    private static func copy(_ profile: Profile, scope: ProfileScope, to destination: URL, progress: @Sendable (Double) -> Void) throws {
        let started = Date()
        guard var config = ProfileIO.readConfig(at: profile.url),
              config.version == ProfileSchema.current else { throw Failure.unsupported }
        let owner = DurableFileStore(root: scope.root, stateRoot: scope.stateRoot)
        try owner.acquire()
        defer { owner.close() }
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        var copied = 0
        var bytes = 0
        for (index, source) in [("content", scope.root), ("state", scope.stateRoot)].enumerated() {
            let (prefix, root) = source
            let target = prefix == "content" ? destination : destination.appendingPathComponent(".ox", isDirectory: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            var enumerationError: Error?
            guard let enumerator = manager.enumerator(at: root,
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
                if prefix == "state", !(["state.sqlite", "service-repositories.json", "logs.jsonl", "payloads"] + AppStoragePaths.profileStateFiles).contains(relative), !relative.hasPrefix("payloads/") {
                    enumerator.skipDescendants()
                    continue
                }
                guard copied + entries.count < maximumEntries else { throw Failure.tooLarge }
                entries.append((url, relative))
            }
            if let enumerationError { throw enumerationError }
            for (entryIndex, entry) in entries.enumerated() {
                let (url, relative) = entry
                try Task.checkCancellation()
                progress(0.2 + 0.75 * (Double(index) + Double(entryIndex + 1) / Double(max(1, entries.count))) / 2)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw Failure.unsafeFile }
                let copy = target.appendingPathComponent(relative)
                if values.isDirectory == true {
                    try manager.createDirectory(at: copy, withIntermediateDirectories: true)
                } else {
                    guard values.isRegularFile == true else { throw Failure.unsafeFile }
                    try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: url, to: copy)
                    bytes += values.fileSize ?? 0
                }
                copied += 1
            }
        }
        guard manager.fileExists(atPath: destination.appendingPathComponent(".ox/state.sqlite").path) else {
            Log.app.error("ProfilePackage.export missingDatabase profile=\(profile.id) entries=\(copied)")
            throw Failure.invalid
        }
        config.contentDirectory = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: destination.appendingPathComponent(ProfileIO.configName), options: .atomic)
        Log.app.info("ProfilePackage.export profile=\(profile.id) entries=\(copied) bytes=\(bytes) seconds=\(Date().timeIntervalSince(started))")
    }
}

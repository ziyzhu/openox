import Foundation
import Observation

@MainActor
@Observable
final class DeviceFolderStore {
    nonisolated struct Grant: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        var bookmark: Data
        let createdAt: Date
    }

    nonisolated enum AccessMode: Sendable {
        case read
        case write
        case delete
    }

    nonisolated enum StoreError: LocalizedError, Sendable {
        case unavailable(String)
        case invalidFolder
        case missingGrant(String)
        case staleGrant(String)
        case denied(String)
        case invalidPath(String)
        case coordination(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): "Files access is unavailable: \(message)"
            case .invalidFolder: "Choose a folder rather than a file."
            case .missingGrant(let id): "The folder grant \(id) no longer exists."
            case .staleGrant(let name): "Access to \(name) expired. Choose the folder again."
            case .denied(let name): "Access to \(name) was denied. Choose the folder again or check Files and Folders in Settings."
            case .invalidPath(let path): "The Files path is invalid: \(path)"
            case .coordination(let message): "The file provider couldn't complete the operation: \(message)"
            }
        }
    }

    static let shared = DeviceFolderStore()

    private(set) var grants: [Grant]
    private let fileURL: URL
    private let mutationCoordinator = FileMutationCoordinator()

    private init() {
        fileURL = ProfileMigrator.migrateDeviceFolderGrants(
            in: AppStoragePaths.applicationSupport,
            destination: AppStoragePaths.deviceFolderGrants
        )
        grants = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Grant].self, from: $0) } ?? []
    }

    @discardableResult
    func add(_ url: URL) async throws -> Grant {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareGrant(url)
        }.value
        return try await mutationCoordinator.perform(key: "grants") {
            let id = uniqueID(for: prepared.name)
            let grant = Grant(id: id, name: prepared.name, bookmark: prepared.bookmark, createdAt: Date())
            var updated = grants
            updated.append(grant)
            updated.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try await persist(updated)
            grants = updated
            Log.app.info("DeviceFolderStore.add id=\(id) name=\(prepared.name)")
            return grant
        }
    }

    func remove(_ id: String) async throws {
        try await mutationCoordinator.perform(key: "grants") {
            guard let index = grants.firstIndex(where: { $0.id == id }) else { throw StoreError.missingGrant(id) }
            let name = grants[index].name
            var updated = grants
            updated.remove(at: index)
            try await persist(updated)
            grants = updated
            Log.app.info("DeviceFolderStore.remove id=\(id) name=\(name)")
        }
    }

    func grant(_ id: String) -> Grant? {
        grants.first { $0.id == id }
    }

    func coordinate<T: Sendable>(
        grantID: String,
        relativePath: [String],
        mode: AccessMode,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        guard let grant = grant(grantID) else { throw StoreError.missingGrant(grantID) }
        return try await Task.detached(priority: .userInitiated) {
            try Self.coordinate(grant: grant, relativePath: relativePath, mode: mode, body)
        }.value
    }

    nonisolated private static func prepareGrant(_ url: URL) throws -> (name: String, bookmark: Data) {
        guard url.startAccessingSecurityScopedResource() else { throw StoreError.denied(url.lastPathComponent) }
        defer { url.stopAccessingSecurityScopedResource() }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .localizedNameKey, .nameKey, .volumeNameKey])
        guard values.isDirectory == true else { throw StoreError.invalidFolder }
        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.localizedNameKey, .nameKey, .volumeNameKey],
            relativeTo: nil
        )
        let localizedName = values.localizedName ?? values.name ?? url.lastPathComponent
        let name = localizedName == "File Provider Storage" ? values.volumeName ?? localizedName : localizedName
        return (name, bookmark)
    }

    nonisolated private static func coordinate<T>(
        grant: Grant,
        relativePath: [String],
        mode: AccessMode,
        _ body: (URL) throws -> T
    ) throws -> T {
        var stale = false
        let root: URL
        do {
            root = try URL(resolvingBookmarkData: grant.bookmark, bookmarkDataIsStale: &stale)
        } catch {
            throw StoreError.unavailable(error.localizedDescription)
        }
        guard !stale else { throw StoreError.staleGrant(grant.name) }
        guard root.startAccessingSecurityScopedResource() else { throw StoreError.denied(grant.name) }
        defer { root.stopAccessingSecurityScopedResource() }
        let target = try safeTarget(root: root, components: relativePath)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        switch mode {
        case .read:
            coordinator.coordinate(readingItemAt: target, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        case .write:
            coordinator.coordinate(writingItemAt: target, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        case .delete:
            coordinator.coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        }
        if let coordinationError { throw StoreError.coordination(coordinationError.localizedDescription) }
        guard let result else { throw StoreError.coordination("No coordinated URL was returned.") }
        return try result.get()
    }

    nonisolated private static func safeTarget(root: URL, components: [String]) throws -> URL {
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) else {
            throw StoreError.invalidPath(components.joined(separator: "/"))
        }
        let standardizedRoot = root.standardizedFileURL
        var target = standardizedRoot
        for component in components {
            target.appendPathComponent(component)
            if FileManager.default.fileExists(atPath: target.path) {
                let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw StoreError.invalidPath(components.joined(separator: "/")) }
            }
        }
        let standardizedTarget = target.standardizedFileURL
        let rootPath = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : standardizedRoot.path + "/"
        guard standardizedTarget == standardizedRoot || standardizedTarget.path.hasPrefix(rootPath) else {
            throw StoreError.invalidPath(components.joined(separator: "/"))
        }
        return standardizedTarget
    }

    private func uniqueID(for name: String) -> String {
        let base = Self.slug(name)
        let existing = Set(grants.map(\.id))
        if !existing.contains(base) { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    nonisolated private static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let parts = folded.lowercased().split { !$0.isLetter && !$0.isNumber }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "folder" : slug
    }

    private func persist(_ grants: [Grant]) async throws {
        let fileURL = fileURL
        try await Task.detached(priority: .utility) {
            try Self.persist(grants, to: fileURL)
        }.value
    }

    nonisolated private static func persist(_ grants: [Grant], to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(grants).write(to: fileURL, options: .atomic)
        try? AppStoragePaths.excludeFromBackup(fileURL)
    }
}

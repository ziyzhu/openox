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
        var profileId: UUID?
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
    private let preparation: Result<Void, Error>
    private let mutationCoordinator = FileMutationCoordinator()
    private var accessedURLs: [String: URL] = [:]
    nonisolated static let didChange = Notification.Name("DeviceFolderStore.didChange")

    private init() {
        let url = AppStoragePaths.deviceFolderGrants
        fileURL = url
        do {
            grants = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode([Grant].self, from: Data(contentsOf: url)) : []
            preparation = .success(())
        } catch {
            grants = []
            preparation = .failure(error)
            Log.app.error("DeviceFolderStore preparation failed sourcePreserved=true error=\(error.localizedDescription)")
        }
    }

    @discardableResult
    func add(_ url: URL, profileId: UUID) async throws -> Grant {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareGrant(url)
        }.value
        return try await mutationCoordinator.perform(key: "grants") {
            let id = uniqueID(for: prepared.name)
            let grant = Grant(id: id, name: prepared.name, bookmark: prepared.bookmark, createdAt: Date(), profileId: profileId)
            var updated = grants
            updated.append(grant)
            updated.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try await persist(updated)
            grants = updated
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            Log.app.info("DeviceFolderStore.add id=\(id) name=\(prepared.name)")
            return grant
        }
    }

    func remove(_ id: String, profileId: UUID) async throws {
        try await mutationCoordinator.perform(key: "grants") {
            _ = try requireGrant(id, profileId: profileId)
            guard let index = grants.firstIndex(where: { $0.id == id }) else { throw StoreError.missingGrant(id) }
            let name = grants[index].name
            var updated = grants
            updated.remove(at: index)
            try await persist(updated)
            grants = updated
            accessedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            Log.app.info("DeviceFolderStore.remove id=\(id) name=\(name)")
        }
    }

    func grant(_ id: String) -> Grant? {
        grants.first { $0.id == id }
    }

    func grants(for profileId: UUID?) -> [Grant] {
        guard let profileId else { return [] }
        return grants.filter { $0.profileId == profileId }
    }

    func requireGrant(_ id: String, profileId: UUID?) throws -> Grant {
        guard let grant = grant(id) else { throw StoreError.missingGrant(id) }
        guard let profileId, grant.profileId == profileId else { throw StoreError.denied(grant.name) }
        return grant
    }

    func assign(_ id: String, profileId: UUID) async throws {
        try await mutationCoordinator.perform(key: "grants") {
            guard let index = grants.firstIndex(where: { $0.id == id }) else { throw StoreError.missingGrant(id) }
            guard grants[index].profileId == nil else { throw StoreError.denied(grants[index].name) }
            var updated = grants
            updated[index].profileId = profileId
            try await persist(updated)
            grants = updated
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            Log.app.info("DeviceFolderStore.assign id=\(id) profile=\(profileId)")
        }
    }

    func repositoryRoot(grantID: String, relativePath: [String], profileId: UUID?) throws -> URL {
        let grant = try requireGrant(grantID, profileId: profileId)
        let root: URL
        if let accessed = accessedURLs[grantID] {
            root = accessed
        } else {
            var stale = false
            root = try FolderBookmarks.resolve(grant.bookmark, stale: &stale)
            guard !stale else { throw StoreError.staleGrant(grant.name) }
            guard root.startAccessingSecurityScopedResource() else { throw StoreError.denied(grant.name) }
            accessedURLs[grantID] = root
        }
        return try Self.safeTarget(root: root, components: relativePath)
    }

    func coordinate<T: Sendable>(
        grantID: String,
        relativePath: [String],
        profileId: UUID?,
        mode: AccessMode,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let grant = try requireGrant(grantID, profileId: profileId)
        return try await Task.detached(priority: .userInitiated) {
            try Self.coordinate(grant: grant, relativePath: relativePath, mode: mode, body)
        }.value
    }

    nonisolated private static func prepareGrant(_ url: URL) throws -> (name: String, bookmark: Data) {
        guard url.startAccessingSecurityScopedResource() else { throw StoreError.denied(url.lastPathComponent) }
        defer { url.stopAccessingSecurityScopedResource() }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .localizedNameKey, .nameKey, .volumeNameKey])
        guard values.isDirectory == true else { throw StoreError.invalidFolder }
        let bookmark = try FolderBookmarks.make(url)
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
            root = try FolderBookmarks.resolve(grant.bookmark, stale: &stale)
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
        "\(Self.slug(name).prefix(48))-\(UUID().uuidString.lowercased())"
    }

    nonisolated private static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let parts = folded.lowercased().split { !$0.isLetter && !$0.isNumber }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "folder" : slug
    }

    private func persist(_ grants: [Grant]) async throws {
        try preparation.get()
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

import Foundation

@MainActor
final class ProfileStore {
    enum StoreError: LocalizedError {
        case invalidFolder
        case denied(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidFolder:
                "Choose a complete Profile folder exported or created by Ox."
            case .denied(let name):
                "Access to \(name) was denied. Choose the folder again or check Files and Folders in Settings."
            case .unavailable(let message):
                "The Profile couldn't be saved: \(message)"
            }
        }
    }

    nonisolated struct ExternalRecord: Codable, Equatable {
        let id: UUID
        let bookmark: Data
        var name: String? = nil
    }

    static let shared = ProfileStore()

    private(set) var unavailable: [ExternalRecord] = []
    private var records: [ExternalRecord]
    private var accessedURLs: Set<URL> = []
    private let fileURL: URL

    private init() {
        let url = AppStoragePaths.externalProfiles
        fileURL = url
        records = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([ExternalRecord].self, from: $0)
        } ?? []
    }

    nonisolated private struct Discovery: Sendable {
        var profiles: [Profile] = []
        var unavailable: [ExternalRecord] = []
        var records: [ExternalRecord]
        var refreshed: [ExternalRecord] = []
        var accessedURLs: Set<URL>
    }

    func profiles(local: URL, cloud: URL?) async -> [Profile] {
        let known = records
        let fileURL = fileURL
        let accessed = accessedURLs
        let discovery = await Task.detached(priority: .userInitiated) {
            Self.discover(known: known, fileURL: fileURL, accessedURLs: accessed, local: local, cloud: cloud)
        }.value
        if records == known { records = discovery.records }
        for record in discovery.refreshed where records.contains(where: { $0.id == record.id }) { upsert(record) }
        accessedURLs.formUnion(discovery.accessedURLs)
        unavailable = discovery.unavailable
        if !discovery.refreshed.isEmpty {
            do { try persist() }
            catch { Log.app.warning("ProfileStore.bookmark refresh unsaved error=\(error.localizedDescription)") }
        }
        return discovery.profiles
    }

    nonisolated private static func discover(known: [ExternalRecord], fileURL: URL, accessedURLs: Set<URL>, local: URL, cloud: URL?) -> Discovery {
        let stored = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([ExternalRecord].self, from: $0) }
        var discovery = Discovery(records: stored ?? known, accessedURLs: accessedURLs)
        var profilesByID: [UUID: Profile] = [:]
        for profile in ProfileIO.registeredProfiles() + managedProfiles(in: local, location: .local) + managedProfiles(in: ProfileIO.publicProfiles, location: .local) + managedProfiles(in: cloud, location: .iCloud) {
            if let existing = profilesByID[profile.id] {
                guard canonical(existing.url) != canonical(profile.url) else { continue }
                Log.app.warning("ProfileStore.duplicate id=\(profile.id) first=\(existing.location.rawValue) second=\(profile.location.rawValue) firstFolder=\(existing.url.lastPathComponent) secondFolder=\(profile.url.lastPathComponent)")
            } else {
                profilesByID[profile.id] = profile
            }
        }
        for record in discovery.records {
            guard let url = resolve(record, local: local, cloud: cloud, discovery: &discovery) else {
                profilesByID.removeValue(forKey: record.id)
                discovery.unavailable.append(record)
                Log.app.warning("ProfileStore.unavailable external id=\(record.id)")
                continue
            }
            guard let profile = ProfileIO.profile(at: url, location: managedLocation(for: url, local: local, cloud: cloud) ?? .external),
                  profile.id == record.id else {
                profilesByID.removeValue(forKey: record.id)
                discovery.unavailable.append(record)
                Log.app.warning("ProfileStore.invalid external id=\(record.id)")
                continue
            }
            profilesByID[profile.id] = profile
        }
        let profiles = Array(profilesByID.values)
        Log.app.info("ProfileStore.discover local=\(profiles.filter { $0.location == .local }.count) iCloud=\(profiles.filter { $0.location == .iCloud }.count) external=\(profiles.filter { $0.location == .external }.count)")
        discovery.profiles = profiles
        return discovery
    }

    func open(_ url: URL, local: URL, cloud: URL?) throws -> Profile {
        if let location = Self.managedLocation(for: url, local: local, cloud: cloud) {
            guard let profile = ProfileIO.profile(at: url, location: location) else { throw StoreError.invalidFolder }
            Log.app.info("ProfileStore.open managed id=\(profile.id) location=\(location.rawValue) name=\(profile.name)")
            return profile
        }
        try access(url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true,
              let profile = ProfileIO.profile(at: url, location: .external) else { throw StoreError.invalidFolder }
        return profile
    }

    func remember(_ profile: Profile) throws {
        let previous = records
        records.removeAll { $0.id == profile.id }
        do {
            let bookmark = try profile.url.bookmarkData(options: .minimalBookmark,
                includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil)
            records.append(ExternalRecord(id: profile.id, bookmark: bookmark, name: profile.name))
            try persist()
        }
        catch { records = previous; throw StoreError.unavailable(error.localizedDescription) }
        Log.app.info("ProfileStore.open id=\(profile.id) location=\(profile.location.rawValue) name=\(profile.name)")
    }

    func accessDirectory(_ url: URL) throws {
        try access(url)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw StoreError.invalidFolder }
    }

    private func access(_ url: URL) throws {
        try Self.access(url, accessedURLs: &accessedURLs)
    }

    nonisolated private static func access(_ url: URL, accessedURLs: inout Set<URL>) throws {
        if accessedURLs.contains(url) { return }
        if url.startAccessingSecurityScopedResource() { accessedURLs.insert(url); return }
        guard canonical(url).pathComponents.starts(with: canonical(ProfileRepository.localDocuments()).pathComponents) else {
            throw StoreError.denied(url.lastPathComponent)
        }
    }

    func remove(_ profile: Profile) throws {
        records.removeAll { $0.id == profile.id }
        if accessedURLs.remove(profile.url) != nil { profile.url.stopAccessingSecurityScopedResource() }
        try persist()
        Log.app.info("ProfileStore.remove id=\(profile.id) location=\(profile.location.rawValue)")
    }

    nonisolated private static func resolve(_ record: ExternalRecord, local: URL, cloud: URL?, discovery: inout Discovery) -> URL? {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: record.bookmark, bookmarkDataIsStale: &stale)
            if managedLocation(for: url, local: local, cloud: cloud) == nil { try access(url, accessedURLs: &discovery.accessedURLs) }
            if stale {
                let bookmark = try url.bookmarkData(options: .minimalBookmark,
                    includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil)
                discovery.refreshed.append(ExternalRecord(id: record.id, bookmark: bookmark, name: record.name))
            }
            return url
        } catch {
            Log.app.warning("ProfileStore.bookmark unavailable id=\(record.id) error=\(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func managedProfiles(in root: URL?, location: Profile.Location) -> [Profile] {
        guard let root else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).compactMap { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                return ProfileIO.profile(at: url, location: location)
            }
        } catch {
            Log.app.info("ProfileStore.discover location=\(location.rawValue) failed: \(error.localizedDescription)")
            return []
        }
    }

    nonisolated private static func managedLocation(for url: URL, local: URL, cloud: URL?) -> Profile.Location? {
        let parent = canonical(url.deletingLastPathComponent())
        if parent == canonical(local) || parent == canonical(ProfileIO.publicProfiles) { return .local }
        if let cloud, parent == canonical(cloud) { return .iCloud }
        return nil
    }

    nonisolated private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func upsert(_ record: ExternalRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
    }

    private func persist() throws {
        let manager = FileManager.default
        if records.isEmpty {
            if manager.fileExists(atPath: fileURL.path) { try manager.removeItem(at: fileURL) }
            return
        }
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(records)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }
}

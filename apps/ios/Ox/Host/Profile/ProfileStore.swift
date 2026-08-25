import Foundation

@MainActor
final class ProfileStore {
    enum StoreError: LocalizedError {
        case invalidFolder
        case unmanagedLayout
        case denied(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidFolder:
                "Choose a Profile folder containing profile.json."
            case .unmanagedLayout:
                "Profiles inside Ox's folders must be directly inside the On My iPhone or iCloud Ox folder."
            case .denied(let name):
                "Access to \(name) was denied. Choose the folder again or check Files and Folders in Settings."
            case .unavailable(let message):
                "The Profile couldn't be saved: \(message)"
            }
        }
    }

    nonisolated struct ExternalRecord: Codable {
        let id: UUID
        let bookmark: Data
    }

    static let shared = ProfileStore()

    private var records: [ExternalRecord]
    private var accessedURLs: [UUID: URL] = [:]
    private let fileURL: URL

    private init() {
        (fileURL, records) = ProfileMigrator.migrateExternalProfiles(
            in: AppStoragePaths.applicationSupport,
            destination: AppStoragePaths.externalProfiles
        )
    }

    func profiles(local: URL, cloud: URL?) -> [Profile] {
        records = loadRecords()
        var profilesByID: [UUID: Profile] = [:]
        for profile in managedProfiles(in: local, location: .local) + managedProfiles(in: cloud, location: .iCloud) {
            if let existing = profilesByID[profile.id] {
                Log.app.warning("ProfileStore.duplicate id=\(profile.id) first=\(existing.location.rawValue) second=\(profile.location.rawValue)")
            } else {
                profilesByID[profile.id] = profile
            }
        }
        for record in records where profilesByID[record.id] == nil {
            guard let url = resolve(record) else {
                Log.app.warning("ProfileStore.unavailable external id=\(record.id)")
                continue
            }
            guard !isInsideManagedRoot(url, local: local, cloud: cloud),
                  let profile = ProfileIO.profile(at: url, location: .external),
                  profile.id == record.id else {
                Log.app.warning("ProfileStore.invalid external id=\(record.id)")
                continue
            }
            profilesByID[profile.id] = profile
        }
        let profiles = Array(profilesByID.values)
        Log.app.info("ProfileStore.discover local=\(profiles.filter { $0.location == .local }.count) iCloud=\(profiles.filter { $0.location == .iCloud }.count) external=\(profiles.filter { $0.location == .external }.count)")
        return profiles
    }

    func open(_ url: URL, local: URL, cloud: URL?) throws -> Profile {
        if let location = managedLocation(for: url, local: local, cloud: cloud) {
            guard let profile = ProfileIO.profile(at: url, location: location) else { throw StoreError.invalidFolder }
            Log.app.info("ProfileStore.open managed id=\(profile.id) location=\(location.rawValue) name=\(profile.name)")
            return profile
        }
        if isInsideManagedRoot(url, local: local, cloud: cloud) { throw StoreError.unmanagedLayout }
        guard url.startAccessingSecurityScopedResource() else { throw StoreError.denied(url.lastPathComponent) }
        var keepAccess = false
        defer {
            if !keepAccess { url.stopAccessingSecurityScopedResource() }
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw StoreError.invalidFolder }
        guard let profile = ProfileIO.profile(at: url, location: .external) else {
            throw StoreError.invalidFolder
        }
        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        if let previous = accessedURLs[profile.id] { previous.stopAccessingSecurityScopedResource() }
        accessedURLs[profile.id] = url
        keepAccess = true
        upsert(ExternalRecord(id: profile.id, bookmark: bookmark))
        do {
            try persist()
        } catch {
            accessedURLs.removeValue(forKey: profile.id)?.stopAccessingSecurityScopedResource()
            throw StoreError.unavailable(error.localizedDescription)
        }
        Log.app.info("ProfileStore.open id=\(profile.id) name=\(profile.name)")
        return profile
    }

    func remove(_ profile: Profile) throws {
        guard profile.location == .external else { return }
        records.removeAll { $0.id == profile.id }
        accessedURLs.removeValue(forKey: profile.id)?.stopAccessingSecurityScopedResource()
        try persist()
        Log.app.info("ProfileStore.remove id=\(profile.id) location=\(profile.location.rawValue)")
    }

    private func resolve(_ record: ExternalRecord) -> URL? {
        if let accessed = accessedURLs[record.id] { return accessed }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: record.bookmark, bookmarkDataIsStale: &stale),
              !stale,
              url.startAccessingSecurityScopedResource() else { return nil }
        accessedURLs[record.id] = url
        return url
    }

    private func managedProfiles(in root: URL?, location: Profile.Location) -> [Profile] {
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

    private func managedLocation(for url: URL, local: URL, cloud: URL?) -> Profile.Location? {
        let parent = canonical(url.deletingLastPathComponent())
        if parent == canonical(local) { return .local }
        if let cloud, parent == canonical(cloud) { return .iCloud }
        return nil
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isInsideManagedRoot(_ url: URL, local: URL, cloud: URL?) -> Bool {
        let components = canonical(url).pathComponents
        return [local, cloud].compactMap { $0 }.contains { root in
            components.starts(with: canonical(root).pathComponents)
        }
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

    private func loadRecords() -> [ExternalRecord] {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([ExternalRecord].self, from: $0) } ?? records
    }
}

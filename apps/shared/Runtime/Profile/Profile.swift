import Foundation

nonisolated struct Profile: Identifiable, Equatable, Sendable {
    nonisolated enum Location: String, Codable, Sendable {
        case local
        case iCloud
        case external
    }

    let id: UUID
    var name: String
    var location: Location
    var url: URL
    let createdAt: Date
    var version: String
}

nonisolated enum ProfileError: LocalizedError {
    case nameExists(String)

    var errorDescription: String? {
        switch self {
        case .nameExists(let name):
            String(format: L10n.string("A Profile named “%@” already exists. Choose a different name.", comment: ""), name)
        }
    }
}

nonisolated struct ProfileScope: Hashable, Sendable {
    let profileID: UUID?
    let root: URL
    let location: Profile.Location
    let generation: UUID
    var stateRoot: URL {
        if ProfileIO.readConfig(at: root)?.version == ProfileMigrator.visibleProfileVersion { return root }
        let portable = ProfileIO.portableStateDirectory(root)
        if FileManager.default.fileExists(atPath: portable.path) { return portable }
        guard let profileID, ProfileIO.readPrivateConfig(profileID)?.contentDirectory != nil else { return root }
        return ProfileIO.stateDirectory(profileID)
    }

    init(profileID: UUID?, root: URL, location: Profile.Location, generation: UUID = UUID()) {
        self.profileID = profileID
        self.root = URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)
        self.location = location
        self.generation = generation
    }
}

nonisolated struct ProfileConfig: Codable, Sendable {
    var id: UUID
    var createdAt: Date
    var version: String
    var contentDirectory: String? = nil

    static var currentVersion: String { ProfileSchema.current }

    static func fresh() -> ProfileConfig {
        ProfileConfig(id: UUID(), createdAt: Date(), version: currentVersion)
    }
}

nonisolated enum ProfileIO {
    static let configName = "profile.json"
    static func portableStateDirectory(_ root: URL) -> URL { root.appendingPathComponent(".ox", isDirectory: true) }

    static var publicProfiles: URL { ProfileRepository.localDocuments().appendingPathComponent("Profiles", isDirectory: true) }
    static var privateProfiles: URL { AppStoragePaths.applicationSupport.appendingPathComponent("Profiles", isDirectory: true) }
    static func stateDirectory(_ id: UUID) -> URL { privateProfiles.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func readPrivateConfig(_ id: UUID) -> ProfileConfig? {
        readManifest(at: stateDirectory(id))
    }

    static func registeredProfiles() -> [Profile] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: privateProfiles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return directories.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent), let config = readPrivateConfig(id), config.id == id,
                  let name = config.contentDirectory, name == ProfileRepository.cleanName(name), !name.hasPrefix("."), !name.contains("/") else { return nil }
            let root = publicProfiles.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { return nil }
            let stored = readManifest(at: root) ?? readManifest(at: portableStateDirectory(root))
            if config.version == ProfileMigrator.portableProfileVersion, stored == nil,
               !FileManager.default.fileExists(atPath: root.appendingPathComponent(".ox-stage-" + id.uuidString).path) { return nil }
            let current = stored ?? config
            guard current.id == id else { return nil }
            return Profile(id: id, name: name, location: .local, url: root, createdAt: current.createdAt, version: current.version)
        }
    }

    static func readConfig(at folder: URL) -> ProfileConfig? {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(configName).path) { return readManifest(at: folder) }
        let portable = portableStateDirectory(folder)
        if FileManager.default.fileExists(atPath: portable.path) { return readManifest(at: portable) }
        if let profile = registeredProfiles().first(where: { $0.url.standardizedFileURL.path == folder.standardizedFileURL.path }) {
            return readPrivateConfig(profile.id)
        }
        return readManifest(at: folder)
    }

    private static func readManifest(at folder: URL) -> ProfileConfig? {
        let url = folder.appendingPathComponent(configName, isDirectory: false)
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data, let config = try? decoder.decode(ProfileConfig.self, from: data) else {
            if let coordError { Log.app.info("ProfileIO.readConfig \(folder.lastPathComponent): \(coordError.localizedDescription)") }
            return nil
        }
        return config
    }

    static func writeConfig(_ config: ProfileConfig, to folder: URL) throws {
        let url = folder.appendingPathComponent(configName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    static func profile(at folder: URL, location: Profile.Location) -> Profile? {
        guard let config = readConfig(at: folder) else { return nil }
        return Profile(
            id: config.id,
            name: folder.lastPathComponent,
            location: location,
            url: folder,
            createdAt: config.createdAt,
            version: config.version
        )
    }

}

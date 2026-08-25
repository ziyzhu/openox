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

    init(profileID: UUID?, root: URL, location: Profile.Location, generation: UUID = UUID()) {
        self.profileID = profileID
        self.root = root
        self.location = location
        self.generation = generation
    }
}

nonisolated struct ProfileConfig: Codable, Sendable {
    var id: UUID
    var createdAt: Date
    var version: String

    static var currentVersion: String { ProfileSchema.current }

    static func fresh() -> ProfileConfig {
        ProfileConfig(id: UUID(), createdAt: Date(), version: currentVersion)
    }
}

nonisolated enum ProfileIO {
    static let configName = "profile.json"

    // A coordinated read so an evicted (cloud-only) profile.json is pulled down and
    // waited on, rather than read as a placeholder.
    static func readConfig(at folder: URL) -> ProfileConfig? {
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

    // A folder is a Profile iff it directly contains a profile.json.
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

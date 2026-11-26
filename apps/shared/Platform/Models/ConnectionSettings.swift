import Foundation

nonisolated struct ConnectionSettings: Codable, Equatable, Sendable {
    var format = 1
    var allowConnections = false

    static func url(for profileID: UUID) -> URL {
        AppStoragePaths.profileConfiguration(profileID).appendingPathComponent("host.json", isDirectory: false)
    }

    static func load(for profileID: UUID) throws -> Self {
        let url = url(for: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.format == 1 else { throw StorageMigrationError.invalidApplicationStorage("Connection settings") }
        return value
    }

    func save(for profileID: UUID) throws {
        try save(to: Self.url(for: profileID))
    }

    func save(to url: URL) throws {
        guard format == 1 else { throw StorageMigrationError.invalidApplicationStorage("Connection settings") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func adoptLegacy(into profileID: UUID) throws {
        let legacy = AppStoragePaths.legacyHostConfiguration
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let value = try load(from: legacy)
        try value.save(for: profileID)
        guard try load(for: profileID) == value else { throw StorageMigrationError.invalidApplicationStorage("Connection settings publication") }
        try FileManager.default.removeItem(at: legacy)
        Log.app.info("StorageMigrator.connectionScope profile=\(profileID) allowConnections=\(value.allowConnections)")
    }
}

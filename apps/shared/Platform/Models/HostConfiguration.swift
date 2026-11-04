import Foundation

nonisolated struct HostConfiguration: Codable, Equatable, Sendable {
    var format = 1
    var allowConnections = false

    static func load() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: AppStoragePaths.hostConfiguration))
        guard value.format == 1 else { throw StorageMigrationError.invalidApplicationStorage("Host configuration") }
        return value
    }

    func save() throws {
        guard format == 1 else { throw StorageMigrationError.invalidApplicationStorage("Host configuration") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: AppStoragePaths.configuration, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: AppStoragePaths.hostConfiguration, options: .atomic)
    }
}

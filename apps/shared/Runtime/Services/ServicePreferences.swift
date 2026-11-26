import Foundation

nonisolated struct ServicePreferences: Codable, Equatable, Sendable {
    var format = 1
    var names: [String: String] = [:]

    func validate() throws {
        guard format == 1, names.keys.allSatisfy({ !$0.isEmpty }) else {
            throw StorageMigrationError.invalidApplicationStorage("service preferences")
        }
    }

    static func load() throws -> Self {
        let url = AppStoragePaths.servicePreferences
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func save() throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = AppStoragePaths.servicePreferences
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

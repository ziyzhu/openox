import Foundation

nonisolated struct ServicePreferences: Codable, Equatable, Sendable {
    var format = 1
    var names: [String: String] = [:]
    var saved: [String] = []

    func validate() throws {
        guard format == 1, Set(saved).count == saved.count,
              saved.allSatisfy({ !$0.isEmpty }), names.keys.allSatisfy({ !$0.isEmpty }) else {
            throw StorageMigrationError.invalidApplicationStorage("service preferences")
        }
    }

    static func load() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: AppStoragePaths.servicePreferences))
        try value.validate()
        return value
    }

    func save() throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: AppStoragePaths.configuration, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: AppStoragePaths.servicePreferences, options: .atomic)
    }
}

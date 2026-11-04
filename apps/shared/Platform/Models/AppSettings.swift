import Foundation

nonisolated struct AppSettings: Codable, Equatable, Sendable {
    var format = 1
    var language = "system"

    func validate() throws {
        guard format == 1, ["system", "en", "zh-Hans"].contains(language) else {
            throw StorageMigrationError.invalidApplicationStorage("app settings")
        }
    }

    static func load() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: AppStoragePaths.settings))
        try value.validate()
        return value
    }

    func save() throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: AppStoragePaths.configuration, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: AppStoragePaths.settings, options: .atomic)
    }
}

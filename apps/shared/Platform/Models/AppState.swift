import Foundation
import Observation

nonisolated struct AppState: Codable, Equatable, Sendable {
    var format = 1
    var onboarded = false
    var memoryIntentDisplays = 0
    var activeProfileID: UUID?
    var chatGPTAgentHostID: String?
    var region: String?

    func validate() throws {
        guard format == 1, (0...3).contains(memoryIntentDisplays),
              region.map({ ["global", "china"].contains($0) }) ?? true,
              chatGPTAgentHostID.map({ !$0.isEmpty && $0.count <= 500 }) ?? true else {
            throw StorageMigrationError.invalidApplicationStorage("app state")
        }
    }

    static func load() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: AppStoragePaths.state))
        try value.validate()
        return value
    }

    func save() throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: AppStoragePaths.applicationSupport, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: AppStoragePaths.state, options: .atomic)
    }
}

@MainActor
@Observable
final class AppStateStore {
    static let shared = AppStateStore()
    private(set) var value: AppState

    private init() {
        value = (try? AppState.load()) ?? AppState()
    }

    func update(_ mutation: (inout AppState) -> Void) throws {
        guard try AppState.load() == value else { throw StorageMigrationError.collision("app state changed externally") }
        var next = value
        mutation(&next)
        try next.save()
        value = next
    }
}

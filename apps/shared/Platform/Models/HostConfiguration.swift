import Foundation

nonisolated struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var endpoint: URL

    var id: URL { endpoint }
}

nonisolated enum HostSelection: Codable, Equatable, Hashable, Sendable {
    case local
    case remote(endpoint: URL)
}

nonisolated struct HostConfiguration: Codable, Equatable, Sendable {
    static let defaultPort: UInt16 = 9876

    var format = 1
    var allowConnections = false
    var remoteHosts: [RemoteHost] = []
    var selection = HostSelection.local

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        allowConnections = try container.decode(Bool.self, forKey: .allowConnections)
        remoteHosts = try container.decodeIfPresent([RemoteHost].self, forKey: .remoteHosts) ?? []
        selection = try container.decodeIfPresent(HostSelection.self, forKey: .selection) ?? .local
        if case .remote(let endpoint) = selection, !remoteHosts.contains(where: { $0.endpoint == endpoint }) {
            selection = .local
        }
    }

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

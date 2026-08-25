import Foundation

@MainActor
struct ServicesMount {
    enum Kind: String, CaseIterable, Sendable {
        case web
        case iOS = "ios"
        case mcp

        var repositoryKind: ServiceRepository.ServiceKind {
            switch self {
            case .web: .web
            case .iOS: .iOS
            case .mcp: .mcp
            }
        }
    }

    struct SourceEntry: Sendable {
        let name: String
        let isDirectory: Bool
        let size: Int?
    }

    struct Entry: Sendable {
        let kind: Kind
        let domain: String
        let manifest: JSONValue

        var directoryPath: String { "services/\(kind.rawValue)/\(domain)" }
        var filePath: String { "\(directoryPath)/service.json" }
        var content: String { ServicesMount.serialize(manifest) }
    }

    enum Error: LocalizedError, Sendable {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let domain): "No service manifest exists for \(domain)."
            }
        }
    }

    let manager: ServiceManager

    static nonisolated func isID(_ id: String) -> Bool {
        !id.isEmpty && id == id.lowercased() && id.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":"
        }
    }

    func entries() -> [Entry] {
        manager.services.map(entry).sorted {
            $0.domain.localizedStandardCompare($1.domain) == .orderedAscending
        }
    }

    func entries(kind: Kind) -> [Entry] {
        entries().filter { $0.kind == kind }
    }

    func entry(kind: Kind, domain: String) throws -> Entry {
        guard let service = manager.service(domain: domain), Self.kind(service) == kind else { throw Error.missing(domain) }
        return entry(service)
    }

    func sourceEntries(kind: Kind, domain: String, path: [String]) async throws -> [SourceEntry] {
        try await manager.listServiceSource(kind: kind, domain: domain, path: path).map {
            SourceEntry(name: $0.name, isDirectory: $0.isDirectory, size: $0.size)
        }
    }

    func sourceIsDirectory(kind: Kind, domain: String, path: [String]) async throws -> Bool {
        try await manager.serviceSourceIsDirectory(kind: kind, domain: domain, path: path)
    }

    func sourceText(kind: Kind, domain: String, path: [String]) async throws -> String {
        let data = try await manager.readServiceSource(kind: kind, domain: domain, path: path)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ServiceRepository.Failure(message: "Service file is not UTF-8 text.")
        }
        return value
    }

    func writeSource(kind: Kind, domain: String, path: [String], content: String) async throws {
        try await manager.writeServiceSource(kind: kind, domain: domain, path: path, data: Data(content.utf8))
    }

    func deleteSource(kind: Kind, domain: String, path: [String]) async throws {
        try await manager.deleteServiceSource(kind: kind, domain: domain, path: path)
    }

    func sourcePaths(kind: Kind, domain: String) async throws -> [String] {
        try await manager.serviceSourcePaths(kind: kind, domain: domain)
    }

    private func entry(_ service: Service) -> Entry {
        Entry(kind: Self.kind(service), domain: service.domain, manifest: service.definition.manifest)
    }

    private static func kind(_ service: Service) -> Kind {
        if service.isIOSService { return .iOS }
        if service.isMCPService { return .mcp }
        return .web
    }

    private static nonisolated func serialize(_ manifest: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest) else { return manifest.jsonString() + "\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

import Foundation

extension ServiceManager {
    static func validateServiceSource(
        kind: ServicesMount.Kind,
        domain: String,
        read: ([String]) async throws -> Data
    ) async throws {
        switch kind {
        case .web, .api:
            let manifestData = try await read(["service.json"])
            let raw = try JSONDecoder().decode(JSONValue.self, from: manifestData)
            let definition = try ServiceDefinition(manifest: raw, repositoryID: Repository.localID, provenance: .local)
            guard definition.domain == domain, definition.isAPI == (kind == .api) else {
                throw Repository.Failure(message: "manifest identity does not match its directory")
            }
            let actionsData = try await read(["actions.js"])
            guard let source = String(data: actionsData, encoding: .utf8) else {
                throw Repository.Failure(message: "actions.js is not UTF-8")
            }
            try ServiceSourceValidation.validateInstaller(source, manifest: raw)
        case .mcp:
            let data = try await read(["service.json"])
            let manifest = try JSONDecoder().decode(MCPCatalogManifest.self, from: data)
            guard manifest.id == domain, manifest.isValid else {
                throw Repository.Failure(message: "invalid MCP manifest")
            }
        case .iOS:
            throw Repository.Failure(message: "Native iOS services cannot be edited in Local.")
        }
    }
}

import Foundation

extension ServiceManager {
    nonisolated struct Listing: Sendable {
        let definition: ServiceDefinition
        var domain: String { definition.domain }
    }

    nonisolated static func decodeListings(
        _ files: [Repository.ManifestFile],
        locale: String?
    ) -> [Listing] {
        let out: [Listing] = files.compactMap { file in
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: file.data) else { return nil }
            let manifest = Manifest.localized(raw, locale: locale)
            do {
                let definition = try ServiceDefinition(
                    manifest: manifest,
                    repositoryID: file.repositoryID,
                    provenance: file.provenance
                )
                guard definition.domain == file.domain else {
                    Log.service.error("ServiceManager.listServices domain mismatch directory=\(file.domain) manifest=\(definition.domain)")
                    return nil
                }
                return Listing(definition: definition)
            } catch {
                Log.service.error("ServiceManager.listServices invalid domain=\(file.domain) error=\(error.localizedDescription)")
                return nil
            }
        }
        return out
    }

    @concurrent
    nonisolated static func decodeMCPDefinitions(
        _ files: [Repository.RepositoryManifestFile], locale: String?
    ) async -> [ServiceDefinition] {
        let definitions = files.compactMap { file -> ServiceDefinition? in
            guard let manifest = try? JSONDecoder().decode(MCPCatalogManifest.self, from: file.data),
                  manifest.id == file.id,
                  manifest.isValid else {
                Log.service.error("ServiceManager.listMCPServices invalid id=\(file.id)")
                return nil
            }
            do {
                return try ServiceDefinition(
                    mcp: manifest.localized(locale),
                    repositoryID: file.repositoryID
                )
            } catch {
                Log.service.error("ServiceManager.listMCPServices invalid id=\(file.id) error=\(error.localizedDescription)")
                return nil
            }
        }
        Log.service.info("ServiceManager.listMCPServices count=\(definitions.count)")
        return definitions
    }
}

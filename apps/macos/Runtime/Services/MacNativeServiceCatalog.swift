import Foundation

nonisolated struct MacNativeServiceCatalog: NativeServiceCatalog {
    @concurrent
    func definitions(files: [Repository.RepositoryManifestFile], locale: String?) async -> [ServiceDefinition] {
        let definitions = files.compactMap { file -> ServiceDefinition? in
            guard ["ios:notifications", "ios:calendar", "ios:reminders", "ios:contacts", "ios:location"].contains(file.id) else { return nil }
            do {
                let manifest = try JSONDecoder().decode(IOSCatalogManifest.self, from: file.data)
                guard manifest.domain == file.id, manifest.isValid else {
                    Log.service.error("MacNativeServiceCatalog invalid id=\(file.id)")
                    return nil
                }
                return try ServiceDefinition(iOS: manifest.localized(locale), repositoryID: file.repositoryID)
            } catch {
                Log.service.error("MacNativeServiceCatalog decode id=\(file.id) error=\(error.localizedDescription)")
                return nil
            }
        }
        Log.service.info("MacNativeServiceCatalog count=\(definitions.count)")
        return definitions
    }
}

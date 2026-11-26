import Foundation

nonisolated protocol NativeServiceCatalog: Sendable {
    func definitions(files: [Repository.RepositoryManifestFile], locale: String?) async -> [ServiceDefinition]
}

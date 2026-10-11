import Foundation

@MainActor
protocol NativeServiceCatalog {
    func definitions(files: [Repository.RepositoryManifestFile], locale: String?) -> [ServiceDefinition]
}

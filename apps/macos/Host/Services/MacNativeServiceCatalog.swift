import Foundation

@MainActor
struct MacNativeServiceCatalog: NativeServiceCatalog {
    func definitions(files: [Repository.RepositoryManifestFile], locale: String?) -> [ServiceDefinition] {
        []
    }
}

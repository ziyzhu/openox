import Foundation
import UIKit

extension ServiceManager {
    convenience init() {
        self.init(nativeServices: IOSNativeServiceCatalog(), memoryWarningNotification: UIApplication.didReceiveMemoryWarningNotification)
    }
}

@MainActor
struct IOSNativeServiceCatalog: NativeServiceCatalog {
    func definitions(files: [Repository.RepositoryManifestFile], locale: String?) -> [ServiceDefinition] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let definitions = files.compactMap { file -> ServiceDefinition? in
            let manifest: IOSCatalogManifest
            do {
                manifest = try JSONDecoder().decode(IOSCatalogManifest.self, from: file.data)
            } catch {
                Log.service.error("ServiceManager.listIOSServices decode id=\(file.id) error=\(error.localizedDescription)")
                return nil
            }
            guard manifest.domain == file.id,
                  manifest.isValid else {
                Log.service.error("ServiceManager.listIOSServices invalid id=\(file.id)")
                return nil
            }
            guard manifest.supports(version) else { return nil }
            do {
                return try ServiceDefinition(
                    iOS: manifest.localized(locale),
                    repositoryID: file.repositoryID
                )
            } catch {
                Log.service.error("ServiceManager.listIOSServices invalid id=\(file.id) error=\(error.localizedDescription)")
                return nil
            }
        }
        Log.service.info("ServiceManager.listIOSServices count=\(definitions.count) os=\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        return definitions
    }
}

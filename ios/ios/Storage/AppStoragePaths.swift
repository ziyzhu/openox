import Foundation

nonisolated enum AppStoragePaths {
    static let appGroupIdentifier = AppConfiguration.appGroupIdentifier
    static let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
    static let caches = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
    )[0]
    static let serviceRepositories = applicationSupport.appendingPathComponent("service-repositories", isDirectory: true)
    static let developmentServiceSnapshot = serviceRepositories.appendingPathComponent("development", isDirectory: true)
    static let serviceRepositoriesConfiguration = applicationSupport.appendingPathComponent("service-repositories.json", isDirectory: false)
    static let logs = applicationSupport.appendingPathComponent("logs.jsonl", isDirectory: false)
    static let externalProfiles = applicationSupport.appendingPathComponent("external-profiles.json", isDirectory: false)
    static let deviceFolderGrants = applicationSupport.appendingPathComponent("device-folder-grants.json", isDirectory: false)
    static let serviceSearchVectors = caches.appendingPathComponent("ServiceSearchVectors.plist", isDirectory: false)

    static func externalProfiles(in support: URL) -> URL {
        support.appendingPathComponent("external-profiles.json", isDirectory: false)
    }

    static func deviceFolderGrants(in support: URL) -> URL {
        support.appendingPathComponent("device-folder-grants.json", isDirectory: false)
    }

    static func appGroupContainer() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { throw CocoaError(.fileNoSuchFile) }
        return container
    }

    static func shareImportsDirectory() throws -> URL {
        try appGroupContainer().appendingPathComponent("ShareImports", isDirectory: true)
    }

    static func pendingShareImportsDirectory() throws -> URL {
        try shareImportsDirectory().appendingPathComponent("Pending", isDirectory: true)
    }

    static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}

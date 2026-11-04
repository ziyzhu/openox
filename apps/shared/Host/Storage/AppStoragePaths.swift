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
    static let repositories = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Repositories", isDirectory: true)
    static let repositoryStaging = applicationSupport.appendingPathComponent("RepositoryStaging", isDirectory: true)
    static let developmentRepositorySnapshot = applicationSupport.appendingPathComponent("service-repositories/development", isDirectory: true)
    static let configuration = applicationSupport.appendingPathComponent("Configuration", isDirectory: true)
    static let settings = configuration.appendingPathComponent("settings.json", isDirectory: false)
    static let actionPolicies = configuration.appendingPathComponent("policy.json", isDirectory: false)
    static let servicePreferences = configuration.appendingPathComponent("services.json", isDirectory: false)
    static let hostConfiguration = configuration.appendingPathComponent("host.json", isDirectory: false)
    static let secretIndex = configuration.appendingPathComponent("secrets.json", isDirectory: false)
    static let state = applicationSupport.appendingPathComponent("state.json", isDirectory: false)
    static let repositoriesConfiguration = configuration.appendingPathComponent("service-repositories.json", isDirectory: false)
    static let mountedRepositories = configuration.appendingPathComponent("mounted-repositories.json", isDirectory: false)
    static let logs = applicationSupport.appendingPathComponent("logs.jsonl", isDirectory: false)
    static let externalProfiles = configuration.appendingPathComponent("external-profiles.json", isDirectory: false)
    static let deviceFolderGrants = configuration.appendingPathComponent("device-folder-grants.json", isDirectory: false)
    static let legacySchedules = applicationSupport.appendingPathComponent("scheduled-skills.json", isDirectory: false)
    static let serviceSearchVectors = caches.appendingPathComponent("ServiceSearchVectors.plist", isDirectory: false)
    static let providersConfiguration = configuration.appendingPathComponent("providers.json", isDirectory: false)
    static let discoveredModels = caches.appendingPathComponent("DiscoveredModels.json", isDirectory: false)
    static let providerModelCatalog = caches.appendingPathComponent("ProviderModelCatalog.json", isDirectory: false)

    static func externalProfiles(in support: URL) -> URL {
        support.appendingPathComponent("Configuration/external-profiles.json", isDirectory: false)
    }

    static func deviceFolderGrants(in support: URL) -> URL {
        support.appendingPathComponent("Configuration/device-folder-grants.json", isDirectory: false)
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

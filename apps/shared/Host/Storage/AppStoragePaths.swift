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
    static var actionPolicies: URL { profileState("policy.json") }
    static var servicePreferences: URL { profileState("services.json") }
    static let legacyHostConfiguration = configuration.appendingPathComponent("host.json", isDirectory: false)
    static var remoteAgentConfiguration: URL { profileState("remote-agents.json") }
    static let profileStateFiles = ["policy.json", "services.json", "providers.json", "remote-agents.json"]
    static let legacySecretIndex = configuration.appendingPathComponent("secrets.json", isDirectory: false)
    static var secretIndex: URL {
        StorageRoot.currentScope?.profileID.map { profileConfiguration($0).appendingPathComponent("secrets.json", isDirectory: false) } ?? legacySecretIndex
    }

    static func profileState(_ name: String) -> URL {
        guard let scope = StorageRoot.currentScope, scope.profileID != nil else { return configuration.appendingPathComponent(name, isDirectory: false) }
        return scope.stateRoot.appendingPathComponent(name, isDirectory: false)
    }

    static func profileConfiguration(_ profileID: UUID) -> URL {
        configuration.appendingPathComponent("profiles", isDirectory: true).appendingPathComponent(profileID.uuidString, isDirectory: true)
    }
    static let state = applicationSupport.appendingPathComponent("state.json", isDirectory: false)
    static let repositoriesConfiguration = configuration.appendingPathComponent("service-repositories.json", isDirectory: false)
    static let mountedRepositories = configuration.appendingPathComponent("mounted-repositories.json", isDirectory: false)
    static let externalProfiles = configuration.appendingPathComponent("external-profiles.json", isDirectory: false)
    static let deviceFolderGrants = configuration.appendingPathComponent("device-folder-grants.json", isDirectory: false)
    static let legacySchedules = applicationSupport.appendingPathComponent("scheduled-skills.json", isDirectory: false)
    static let serviceSearchVectors = caches.appendingPathComponent("ServiceSearchVectors.plist", isDirectory: false)
    static var providersConfiguration: URL { profileState("providers.json") }
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

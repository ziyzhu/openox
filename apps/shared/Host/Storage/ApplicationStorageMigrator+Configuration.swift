import Foundation

nonisolated extension ApplicationStorageMigrator {
    static func legacyPreference(_ key: String, defaults: UserDefaults = .standard) -> Any? {
        guard defaults === UserDefaults.standard else { return defaults.object(forKey: key) }
        return defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key]
    }

    static func migrateConfigurationLocations() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: AppStoragePaths.configuration, withIntermediateDirectories: true)
        let names = ["providers.json", "service-repositories.json", "mounted-repositories.json", "external-profiles.json", "device-folder-grants.json"]
        for name in names {
            let source = AppStoragePaths.applicationSupport.appendingPathComponent(name)
            let destination = AppStoragePaths.configuration.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw StorageMigrationError.invalidApplicationStorage(name)
            }
            let data = try Data(contentsOf: source)
            if manager.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == data else { throw StorageMigrationError.collision(name) }
            } else {
                try data.write(to: destination, options: .atomic)
                guard try Data(contentsOf: destination) == data else { throw StorageMigrationError.invalidApplicationStorage(name) }
            }
            try manager.removeItem(at: source)
            Log.app.info("StorageMigrator.configurationLocation done file=\(name)")
        }
    }

    static func migrateEarlyStateStorage(defaults: UserDefaults = .standard) throws {
        try migrateState(defaults: defaults)
    }

    static func migrateStateAndServiceStorage(defaults: UserDefaults = .standard) throws {
        try migrateState(defaults: defaults)
        try migrateLegacyHostPreference(defaults: defaults)
        try migrateServicePreferences(defaults: defaults)
    }

    private static func migrateState(defaults: UserDefaults) throws {
        let exists = FileManager.default.fileExists(atPath: AppStoragePaths.state.path)
        let current = exists ? try AppState.load() : AppState()
        var next = current
        let keys = ["app.hasCompletedOnboarding", "conversation.importMemoryIntentDisplays", "storage.activeProfile", "chatgpt.agentHostID", "app.region"]
        if let value = legacyPreference(keys[0], defaults: defaults) {
            guard let value = value as? Bool else { throw StorageMigrationError.invalidApplicationStorage("onboarding") }
            next.onboarded = value
        }
        if let value = legacyPreference(keys[1], defaults: defaults) {
            guard let value = value as? Int else { throw StorageMigrationError.invalidApplicationStorage("starter count") }
            next.memoryIntentDisplays = min(3, max(0, value))
        }
        if let value = legacyPreference(keys[2], defaults: defaults) {
            guard let value = value as? String, let id = UUID(uuidString: value) else {
                throw StorageMigrationError.invalidApplicationStorage("active Profile")
            }
            next.activeProfileID = id
        }
        if let value = legacyPreference(keys[3], defaults: defaults) {
            guard let value = value as? String else { throw StorageMigrationError.invalidApplicationStorage("installation identity") }
            next.chatGPTAgentHostID = value
        }
        if let value = legacyPreference(keys[4], defaults: defaults) {
            guard let value = value as? String else { throw StorageMigrationError.invalidApplicationStorage("region") }
            next.region = value
        }
        try next.validate()
        if exists {
            guard next == current else {
                let fields = [next.onboarded != current.onboarded ? "onboarded" : nil,
                              next.memoryIntentDisplays != current.memoryIntentDisplays ? "starterCount" : nil,
                              next.activeProfileID != current.activeProfileID ? "activeProfile" : nil,
                              next.chatGPTAgentHostID != current.chatGPTAgentHostID ? "installationIdentity" : nil,
                              next.region != current.region ? "region" : nil].compactMap { $0 }
                Log.app.error("StorageMigrator.appState collision fields=\(fields.joined(separator: ","))")
                throw StorageMigrationError.collision("app state")
            }
        } else {
            try next.save()
            guard try AppState.load() == next else { throw StorageMigrationError.invalidApplicationStorage("app state publication") }
            Log.app.info("StorageMigrator.appState done format=1")
        }
        try removeMigratedPreferences(keys, defaults: defaults)
    }

    private static func migrateLegacyHostPreference(defaults: UserDefaults) throws {
        let key = "host.allowConnections"
        guard let preference = legacyPreference(key, defaults: defaults) else { return }
        guard let value = preference as? Bool else { throw StorageMigrationError.invalidApplicationStorage("Host access") }
        let url = AppStoragePaths.legacyHostConfiguration
        if FileManager.default.fileExists(atPath: url.path) {
            guard try ConnectionSettings.load(from: url).allowConnections == value else { throw StorageMigrationError.collision("Connection settings") }
        } else {
            var next = ConnectionSettings()
            next.allowConnections = value
            try next.save(to: url)
            guard try ConnectionSettings.load(from: url) == next else { throw StorageMigrationError.invalidApplicationStorage("Connection settings publication") }
            Log.app.info("StorageMigrator.legacyHostPreference done format=1")
        }
        try removeMigratedPreferences([key], defaults: defaults)
    }

    private static func migrateServicePreferences(defaults: UserDefaults) throws {
        guard !CredentialMigrator.configurationInProfiles else { return }
        let exists = FileManager.default.fileExists(atPath: AppStoragePaths.servicePreferences.path)
        let current = exists ? try ServicePreferences.load() : ServicePreferences()
        var next = current
        if let value = legacyPreference(ServiceManager.serviceNamesKey, defaults: defaults) {
            guard let value = value as? [String: String] else { throw StorageMigrationError.invalidApplicationStorage("service names") }
            next.names = value
        }
        try next.validate()
        if exists {
            guard next == current else { throw StorageMigrationError.collision("service preferences") }
        } else {
            try next.save()
            guard try ServicePreferences.load() == next else { throw StorageMigrationError.invalidApplicationStorage("service preferences publication") }
            Log.app.info("StorageMigrator.servicePreferences done format=1")
        }
        try removeMigratedPreferences([ServiceManager.serviceNamesKey], defaults: defaults)
    }

    private static func removeMigratedPreferences(_ keys: [String], defaults: UserDefaults) throws {
        guard keys.contains(where: { legacyPreference($0, defaults: defaults) != nil }) else { return }
        for key in keys { defaults.removeObject(forKey: key) }
        guard defaults.synchronize() else { throw StorageMigrationError.invalidApplicationStorage("configuration preference cleanup") }
    }
}

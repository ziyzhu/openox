import Foundation

nonisolated enum ApplicationStorageMigrator {
    private struct LegacyProfileRecord: Decodable {
        let id: UUID
        let location: Profile.Location
        let bookmark: Data?
    }

    @MainActor
    static func migrate() {
        Log.app.info("StorageMigrator.application start")
        migrateExternalProfiles(
            in: AppStoragePaths.applicationSupport,
            destination: AppStoragePaths.externalProfiles
        )
        migrateDeviceFolderGrants(
            in: AppStoragePaths.applicationSupport,
            destination: AppStoragePaths.deviceFolderGrants
        )
        migrateRemoteMCPServers(
            defaults: .standard,
            currentKey: RepositoryMigrator.legacyRemoteMCPKey
        )
        migrateCustomLLMProviders(
            defaults: .standard,
            key: ProviderRegistry.customProvidersKey
        )
        migrateDefaultModel(defaults: .standard, fallbackRegion: AppRegion.shared.region)
        do { try removeRetiredGemma() }
        catch { Log.app.error("StorageMigrator.retiredGemma failed error=\(error.localizedDescription)") }
        do { try migrateProviderCatalog(defaults: .standard) }
        catch { Log.app.error("StorageMigrator.providerCatalog failed error=\(error.localizedDescription)") }
        migrateActionApprovalPolicies()
        migrateFilesPolicies()
        migrateFolderOwnership()
        migrateSavedServices()
        migrateTheme()
        CredentialMigrator.removeLegacyRepositoryAuthorization()
        Log.app.info("StorageMigrator.application done")
    }

    private static func removeRetiredGemma(
        defaults: UserDefaults = .standard,
        support: URL = AppStoragePaths.applicationSupport
    ) throws {
        let providerID = "on-device-gemma"
        let names = ["gemma-4-e2b-it.litertlm", "gemma-4-e2b-it.json"]
        let manager = FileManager.default
        var removedFiles = 0
        for directory in ["models", "on-device-models"] {
            let root = support.appendingPathComponent(directory, isDirectory: true)
            for name in names {
                let url = root.appendingPathComponent(name)
                guard manager.fileExists(atPath: url.path) else { continue }
                try manager.removeItem(at: url)
                removedFiles += 1
            }
        }
        let selection = defaults.data(forKey: ProviderRegistry.defaultModelKey)
            .flatMap { try? JSONDecoder().decode(ModelSelection.self, from: $0) }
        let clearedDefault = selection?.providerID == providerID
        if clearedDefault { defaults.removeObject(forKey: ProviderRegistry.defaultModelKey) }
        if removedFiles > 0 || clearedDefault {
            Log.app.info("StorageMigrator.retiredGemma removedFiles=\(removedFiles) clearedDefault=\(clearedDefault)")
        }
    }

    private static func migrateTheme(
        defaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: AppStoragePaths.appGroupIdentifier)
    ) {
        let key = "app.theme"
        guard let legacyValue = defaults.string(forKey: key) else { return }
        guard let sharedDefaults else {
            Log.app.error("StorageMigrator.theme app-group unavailable")
            return
        }
        if sharedDefaults.string(forKey: key) == nil {
            sharedDefaults.set(legacyValue, forKey: key)
        }
        let saved = sharedDefaults.synchronize()
        if saved {
            defaults.removeObject(forKey: key)
            defaults.synchronize()
        }
        Log.app.info("StorageMigrator.theme migrated saved=\(saved)")
    }

    private static func migrateActionApprovalPolicies(defaults: UserDefaults = .standard) {
        let retired = Set(["ox.app.inspect"])
        if let data = defaults.data(forKey: ServiceManager.actionPoliciesKey) {
            do {
                let stored = try JSONDecoder().decode(ActionPolicyConfiguration.self, from: data)
                let migratedFormat = stored.format == ActionPolicyConfiguration.legacyFormat
                guard stored.format == ActionPolicyConfiguration.currentFormat || migratedFormat else {
                    Log.app.error("StorageMigrator.actionPolicies deferred format=\(stored.format)")
                    return
                }
                var configuration = migratedFormat
                    ? ActionPolicyConfiguration(
                        defaultPolicy: stored.defaultPolicy == .ask ? nil : stored.defaultPolicy,
                        sources: stored.sources,
                        actions: stored.actions
                    )
                    : stored
                let originalCount = configuration.actions.count
                let storedActions = configuration.actions
                let renamedCount = storedActions.keys.filter { canonicalApprovalAction($0) != $0 }.count
                var migratedActions = storedActions.reduce(into: [String: ActionPolicy]()) { actions, entry in
                    guard !isRetiredApproval(entry.key, retired: retired), !entry.key.hasPrefix("ios:files:") else { return }
                    let action = canonicalApprovalAction(entry.key)
                    guard action == entry.key else { return }
                    actions[action] = entry.value
                }
                for entry in storedActions.sorted(by: { $0.key < $1.key }) {
                    guard !isRetiredApproval(entry.key, retired: retired), !entry.key.hasPrefix("ios:files:") else { continue }
                    let action = canonicalApprovalAction(entry.key)
                    if migratedActions[action] == nil { migratedActions[action] = entry.value }
                }
                configuration.actions = migratedActions
                if migratedFormat || configuration.actions != storedActions,
                   let updated = try? JSONEncoder().encode(configuration) {
                    defaults.set(updated, forKey: ServiceManager.actionPoliciesKey)
                }
                defaults.removeObject(forKey: ServiceManager.legacyAutoApproveActionsKey)
                defaults.removeObject(forKey: ServiceManager.legacyAutoApproveAllKey)
                defaults.synchronize()
                Log.app.info("StorageMigrator.actionPolicies current format=\(configuration.format) migrated=\(migratedFormat) actions=\(configuration.actions.count) renamed=\(renamedCount) removed=\(originalCount - configuration.actions.count)")
            } catch {
                Log.app.error("StorageMigrator.actionPolicies invalid preserved=true error=\(error.localizedDescription)")
            }
            return
        }

        let legacy = defaults.stringArray(forKey: ServiceManager.legacyAutoApproveActionsKey) ?? []
        let retained = Set(legacy).filter { !isRetiredApproval($0, retired: retired) && !$0.hasPrefix("ios:files:") }
        let actions = retained.sorted().reduce(into: [String: ActionPolicy]()) { actions, action in
            actions[canonicalApprovalAction(action)] = .allow
        }
        let allowsAll = defaults.bool(forKey: ServiceManager.legacyAutoApproveAllKey)
        let configuration = ActionPolicyConfiguration(
            defaultPolicy: allowsAll ? .allow : nil,
            actions: actions
        )
        do {
            let encoded = try JSONEncoder().encode(configuration)
            defaults.set(encoded, forKey: ServiceManager.actionPoliciesKey)
            guard defaults.synchronize(), defaults.data(forKey: ServiceManager.actionPoliciesKey) == encoded else {
                Log.app.error("StorageMigrator.actionPolicies write failed legacyPreserved=true")
                return
            }
            defaults.removeObject(forKey: ServiceManager.legacyAutoApproveActionsKey)
            defaults.removeObject(forKey: ServiceManager.legacyAutoApproveAllKey)
            defaults.synchronize()
            Log.app.info("StorageMigrator.actionPolicies migrated actions=\(configuration.actions.count) retired=\(legacy.count - retained.count) default=\(configuration.defaultPolicy?.rawValue ?? "automatic")")
        } catch {
            Log.app.error("StorageMigrator.actionPolicies encode failed legacyPreserved=true error=\(error.localizedDescription)")
        }
    }

    private static func isRetiredApproval(_ action: String, retired: Set<String>) -> Bool {
        retired.contains(action) || BrowserFunctionCatalog.isLegacyApproval(action)
    }

    private static func migrateFolderOwnership() {
        let url = AppStoragePaths.deviceFolderGrants
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            _ = try JSONDecoder().decode([DeviceFolderStore.Grant].self, from: data)
            guard var records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            var changed = 0
            for index in records.indices where records[index]["profileId"] == nil {
                records[index]["profileId"] = NSNull()
                changed += 1
            }
            guard changed > 0 else { return }
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            Log.app.info("StorageMigrator.folderOwnership unassigned=\(changed) bookmarksPreserved=true")
        } catch { Log.app.error("StorageMigrator.folderOwnership failed error=\(error.localizedDescription)") }
    }

    private static func migrateFilesPolicies(defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: ServiceManager.actionPoliciesKey) else { return }
        do {
            var configuration = try JSONDecoder().decode(ActionPolicyConfiguration.self, from: data)
            guard configuration.format == ActionPolicyConfiguration.currentFormat else { return }
            let policy = configuration.sources.removeValue(forKey: "ios:files")
            let attachment = configuration.actions.removeValue(forKey: "ox.service.attach:ios:files")
            guard policy != nil || attachment != nil else { return }
            if let policy {
                for action in OxFileSystem.actions where configuration.actions[action] == nil {
                    configuration.actions[action] = policy
                }
            }
            defaults.set(try JSONEncoder().encode(configuration), forKey: ServiceManager.actionPoliciesKey)
            defaults.synchronize()
            Log.app.info("StorageMigrator.filesPolicies migrated=true")
        } catch { Log.app.error("StorageMigrator.filesPolicies failed error=\(error.localizedDescription)") }
    }

    private static func migrateSavedServices(defaults: UserDefaults = .standard) {
        guard let stored = defaults.stringArray(forKey: ServiceManager.savedKey) else { return }
        let retained = stored.filter { $0 != BrowserFunctionCatalog.internalDomain && $0 != "ios:files" }
        guard retained != stored else { return }
        defaults.set(retained, forKey: ServiceManager.savedKey)
        defaults.synchronize()
        Log.app.info("StorageMigrator.savedServices retiredBrowser=\(stored.count - retained.count)")
    }

    private static func canonicalApprovalAction(_ action: String) -> String {
        switch action {
        case "ox.chat.start": return "ox.conversation.start"
        case "ox.chat.delete": return "ox.conversation.delete"
        default: break
        }
        let renamed = action.replacingOccurrences(of: "ox.service.repository.", with: "ox.repository.")
            .replacingOccurrences(of: "ox.service.git.", with: "ox.repository.git.")
            .replacingOccurrences(of: "ox.app.serviceRepositories", with: "ox.app.repositories")
        if renamed != action { return renamed }
        if action.hasPrefix("ox.") || action.hasPrefix("web:") || action.hasPrefix("api:")
            || action.hasPrefix("ios:") || action.hasPrefix("mcp:") {
            return action
        }
        guard let separator = action.lastIndex(of: ":"), action[..<separator].contains(".") else { return action }
        return "web:\(action)"
    }

    static func validateApplicationStorage() throws {
        let manager = FileManager.default
        let support = AppStoragePaths.applicationSupport
        let legacyProfiles = support
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
        if manager.fileExists(atPath: legacyProfiles.path),
           !manager.fileExists(atPath: AppStoragePaths.externalProfiles.path) {
            throw StorageMigrationError.invalidApplicationStorage("Profile catalog")
        }
        try validateFile(
            AppStoragePaths.externalProfiles,
            as: [ProfileStore.ExternalRecord].self,
            component: "Profile catalog"
        )

        let legacyGrants = support
            .appendingPathComponent("device-folders", isDirectory: true)
            .appendingPathComponent("grants.json", isDirectory: false)
        if manager.fileExists(atPath: legacyGrants.path),
           !manager.fileExists(atPath: AppStoragePaths.deviceFolderGrants.path) {
            throw StorageMigrationError.invalidApplicationStorage("folder grants")
        }
        try validateFile(
            AppStoragePaths.deviceFolderGrants,
            as: [DeviceFolderStore.Grant].self,
            component: "folder grants"
        )
        let defaults = UserDefaults.standard
        do {
            guard let data = defaults.data(forKey: ProviderRegistry.catalogKey) else {
                throw StorageMigrationError.invalidApplicationStorage("provider catalog")
            }
            try JSONDecoder().decode(ProviderCatalog.self, from: data).validate()
            if let selection = defaults.data(forKey: ProviderRegistry.defaultModelKey),
               let object = try JSONSerialization.jsonObject(with: selection) as? [String: Any], object["region"] != nil {
                throw StorageMigrationError.invalidApplicationStorage("provider selection")
            }
        } catch { throw StorageMigrationError.invalidApplicationStorage("provider catalog") }
        if defaults.object(forKey: RepositoryMigrator.legacyRemoteMCPKey) != nil {
            guard let data = defaults.data(forKey: RepositoryMigrator.legacyRemoteMCPKey),
                  (try? JSONDecoder().decode([RepositoryMigrator.LegacyRemoteMCP].self, from: data)) != nil else {
                throw StorageMigrationError.invalidApplicationStorage("remote MCP server")
            }
        }
        if defaults.object(forKey: ProviderRegistry.customProvidersKey) != nil {
            guard let data = defaults.data(forKey: ProviderRegistry.customProvidersKey),
                  (try? JSONDecoder().decode([CustomLLMProvider].self, from: data)) != nil else {
                throw StorageMigrationError.invalidApplicationStorage("custom provider")
            }
        }
        if defaults.object(forKey: ProviderRegistry.defaultModelKey) != nil {
            guard let data = defaults.data(forKey: ProviderRegistry.defaultModelKey),
                  (try? JSONDecoder().decode(ModelSelection.self, from: data)) != nil else {
                throw StorageMigrationError.invalidApplicationStorage("default model")
            }
        }
    }

    private static func validateFile<Value: Decodable>(
        _ url: URL,
        as type: Value.Type,
        component: String
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            _ = try JSONDecoder().decode(type, from: data)
        } catch {
            Log.app.error("StorageMigrator.validate component=\(component) failed=\(error.localizedDescription)")
            throw StorageMigrationError.invalidApplicationStorage(component)
        }
    }

    private static func migrateExternalProfiles(
        in support: URL,
        destination: URL? = nil
    ) {
        let destination = destination ?? AppStoragePaths.externalProfiles(in: support)
        let legacyDirectory = support.appendingPathComponent("profiles", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        if let data = try? Data(contentsOf: destination),
           (try? JSONDecoder().decode([ProfileStore.ExternalRecord].self, from: data)) != nil {
            do {
                try removeLegacyFile(legacyURL, directory: legacyDirectory)
            } catch {
                Log.app.error("StorageMigrator.externalProfiles cleanup failed: \(error.localizedDescription)")
            }
            return
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([LegacyProfileRecord].self, from: data) else {
            return
        }
        let records: [ProfileStore.ExternalRecord] = legacy.compactMap { record in
            guard record.location == .external, let bookmark = record.bookmark else { return nil }
            return ProfileStore.ExternalRecord(id: record.id, bookmark: bookmark)
        }
        do {
            if !records.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var encoded = try encoder.encode(records)
                encoded.append(0x0A)
                try encoded.write(to: destination, options: Data.WritingOptions.atomic)
            }
            try removeLegacyFile(legacyURL, directory: legacyDirectory)
            Log.app.info("StorageMigrator.externalProfiles migrated=\(records.count) discardedManaged=\(legacy.count - records.count)")
        } catch {
            Log.app.error("StorageMigrator.externalProfiles failed: \(error.localizedDescription)")
        }
    }

    private static func migrateDeviceFolderGrants(in support: URL, destination: URL? = nil) {
        let destination = destination ?? AppStoragePaths.deviceFolderGrants(in: support)
        let legacyDirectory = support.appendingPathComponent("device-folders", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("grants.json", isDirectory: false)
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: destination),
           (try? decoder.decode([DeviceFolderStore.Grant].self, from: data)) != nil {
            do {
                try removeLegacyFile(legacyURL, directory: legacyDirectory)
            } catch {
                Log.app.error("StorageMigrator.deviceFolderGrants cleanup failed: \(error.localizedDescription)")
            }
            return
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let grants = try? decoder.decode([DeviceFolderStore.Grant].self, from: data) else {
            return
        }
        do {
            try data.write(to: destination, options: .atomic)
            try? AppStoragePaths.excludeFromBackup(destination)
            try removeLegacyFile(legacyURL, directory: legacyDirectory)
            Log.app.info("StorageMigrator.deviceFolderGrants migrated=\(grants.count)")
        } catch {
            Log.app.error("StorageMigrator.deviceFolderGrants failed: \(error.localizedDescription)")
        }
    }

    private static func migrateRemoteMCPServers(
        defaults: UserDefaults,
        currentKey: String
    ) {
        let legacyKey = "remoteMCPEndpoints"
        if let data = defaults.data(forKey: currentKey),
           (try? JSONDecoder().decode([RepositoryMigrator.LegacyRemoteMCP].self, from: data)) != nil {
            defaults.removeObject(forKey: legacyKey)
            return
        }
        let migrated = (defaults.stringArray(forKey: legacyKey) ?? []).map {
            RepositoryMigrator.LegacyRemoteMCP(endpoint: $0, transport: nil, faviconURL: nil)
        }
        guard !migrated.isEmpty else { return }
        do {
            defaults.set(try JSONEncoder().encode(migrated), forKey: currentKey)
            defaults.removeObject(forKey: legacyKey)
            Log.app.info("StorageMigrator.remoteMCPServers migrated=\(migrated.count)")
        } catch {
            Log.app.error("StorageMigrator.remoteMCPServers failed: \(error.localizedDescription)")
        }
    }

    private static func migrateCustomLLMProviders(
        defaults: UserDefaults,
        key: String
    ) {
        guard let data = defaults.data(forKey: key) else { return }
        do {
            let providers = try JSONDecoder().decode([CustomLLMProvider].self, from: data)
            let legacyModelsStored = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            if legacyModelsStored?.contains(where: { $0["models"] != nil }) == true {
                defaults.set(try JSONEncoder().encode(providers), forKey: key)
                Log.app.info("StorageMigrator.customLLMProviders removed legacy models providers=\(providers.count)")
            }
        } catch {
            Log.app.error("StorageMigrator.customLLMProviders failed error=\(error.localizedDescription)")
        }
    }

    private static func migrateDefaultModel(
        defaults: UserDefaults,
        fallbackRegion: LLMRegion
    ) {
        let selectedModelsKey = "llm.selectedModels"
        let selectedReasoningEffortsKey = "llm.selectedReasoningEfforts"
        let defaultProviderKey = "llm.defaultClient"
        let defaultRegionKey = "llm.defaultRegion"
        let legacyKeys = [
            selectedModelsKey,
            selectedReasoningEffortsKey,
            defaultProviderKey,
            defaultRegionKey,
        ]
        if let data = defaults.data(forKey: ProviderRegistry.defaultModelKey),
           let stored = try? JSONDecoder().decode(ModelSelection.self, from: data) {
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let region = (object?["region"] as? String).flatMap(LLMRegion.init(rawValue:)) {
                object?["providerID"] = StorageMigrationSupport.providerIdentity(stored.providerID, region: region, modelID: stored.modelID)
                object?.removeValue(forKey: "region")
                if let object, let current = try? JSONSerialization.data(withJSONObject: object) {
                    defaults.set(current, forKey: ProviderRegistry.defaultModelKey)
                }
            }
            legacyKeys.forEach { defaults.removeObject(forKey: $0) }
            return
        }
        guard defaults.object(forKey: ProviderRegistry.defaultModelKey) == nil else { return }
        let hasLegacyValue = legacyKeys.contains { defaults.object(forKey: $0) != nil }
        guard hasLegacyValue else { return }
        let region = defaults.string(forKey: defaultRegionKey).flatMap(LLMRegion.init(rawValue:)) ?? fallbackRegion
        let providerID = defaults.string(forKey: defaultProviderKey)
        let selectedModels = defaults.dictionary(forKey: selectedModelsKey) as? [String: String] ?? [:]
        let modelID = providerID.flatMap {
            selectedModels["\(region.rawValue)\u{1F}\($0)"] ?? selectedModels[$0]
        }
        let selection: ModelSelection?
        if let providerID, let modelID {
            let efforts = defaults.dictionary(forKey: selectedReasoningEffortsKey) as? [String: String] ?? [:]
            selection = ModelSelection(
                region: region,
                providerID: StorageMigrationSupport.providerIdentity(providerID, region: region, modelID: modelID),
                modelID: modelID,
                reasoningEffort: efforts["\(providerID)\u{1F}\(modelID)"]
            )
        } else {
            selection = nil
        }
        do {
            if let selection {
                defaults.set(try JSONEncoder().encode(selection), forKey: ProviderRegistry.defaultModelKey)
                guard let data = defaults.data(forKey: ProviderRegistry.defaultModelKey),
                      (try? JSONDecoder().decode(ModelSelection.self, from: data)) == selection else {
                    Log.app.error("StorageMigrator.defaultModel verification failed")
                    return
                }
            }
            legacyKeys.forEach { defaults.removeObject(forKey: $0) }
            Log.app.info("StorageMigrator.defaultModel migrated complete=\(selection != nil)")
        } catch {
            Log.app.error("StorageMigrator.defaultModel failed error=\(error.localizedDescription)")
        }
    }

    static func prepareScheduledSkills(at file: URL) throws -> [ScheduledSkill] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        try migrateScheduledSkillPackages(at: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ScheduledSkillsDocument.self, from: Data(contentsOf: file))
        let schedules = try document.validated().schedules
        Log.app.info("StorageMigrator.schedules prepared version=\(document.version) count=\(schedules.count)")
        return schedules
    }

    private static func migrateScheduledSkillPackages(at file: URL) throws {
        guard var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              document["version"] as? Int == 1, var schedules = document["schedules"] as? [[String: Any]] else { return }
        for index in schedules.indices {
            guard var skill = schedules[index]["skill"] as? [String: Any], let instructions = skill["instructions"] as? String else { throw SkillError.invalidPackage }
            skill["instructions"] = StorageMigrationSupport.migratedSkillInstructions(instructions)
            if let name = skill["name"] as? String, ["import-memory", "manage-artifacts", "manage-services", "manage-skills"].contains(name) { skill["name"] = "user-" + name }
            schedules[index]["skill"] = skill
        }
        document["version"] = 2
        document["schedules"] = schedules
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _ = try decoder.decode(ScheduledSkillsDocument.self, from: data).validated()
        try data.write(to: file, options: .atomic)
        Log.app.info("StorageMigrator.scheduledSkills from=1 to=2 count=\(schedules.count)")
    }

    nonisolated private static func removeLegacyFile(_ url: URL, directory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
        if try manager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try manager.removeItem(at: directory)
        }
    }

    private static func migrateProviderCatalog(defaults: UserDefaults) throws {
        func copyCredential(_ source: String, _ destination: String) throws {
            guard source != destination, let value = Credentials.legacyKey(for: source) else { return }
            if let existing = Credentials.legacyKey(for: destination), existing != value {
                throw StorageMigrationError.collision("provider credential")
            }
            try Credentials.setSecretChecked(value, for: "api:\(destination)")
        }
        let existing = defaults.data(forKey: ProviderRegistry.catalogKey)
        if let existing {
            let catalog = try JSONDecoder().decode(ProviderCatalog.self, from: existing)
            if catalog.format == 2 {
                try removeWebsiteProviderOverrides(from: catalog, defaults: defaults)
                return
            }
            guard catalog.format == 1 else {
                throw StorageMigrationError.invalidApplicationStorage("provider catalog")
            }
        }
        let bundled = ProviderRegistry.bundledDefinitions()
        for entry in bundled {
            _ = try ProviderDefinition.decode(entry.definition.json)
            try ProviderClientFactory.validateAdapter(entry.definition)
        }
        var catalog = ProviderCatalog()
        let selection = defaults.data(forKey: ProviderRegistry.defaultModelKey).flatMap { try? JSONDecoder().decode(ModelSelection.self, from: $0) }
        if let existing {
            struct Overlay: Decodable {
                let providers: [ProviderDefinition]
                let deleted: [String]
            }
            let overlay = try JSONDecoder().decode(Overlay.self, from: existing)
            let providers = overlay.providers.filter { $0.api != .web }
            try ProviderCatalog(providers: providers).validate()
            guard Set(overlay.deleted).count == overlay.deleted.count,
                  Set(overlay.deleted).isDisjoint(with: Set(overlay.providers.map(\.id))) else {
                throw StorageMigrationError.invalidApplicationStorage("provider catalog")
            }
            catalog.providers = providers
            for entry in bundled where overlay.deleted.contains(entry.definition.id) {
                var disabled = entry.definition
                disabled.models = []
                catalog.providers.append(disabled)
            }
        } else if let data = defaults.data(forKey: ProviderRegistry.customProvidersKey) {
            let custom = try JSONDecoder().decode([CustomLLMProvider].self, from: data)
            for provider in custom {
                var definition = provider.definition
                if selection?.providerID == provider.clientID, let modelID = selection?.modelID {
                    var model = ProviderDefinition.Model(ProviderModel(id: modelID, displayName: modelID, maxTokens: 4_096, maxContext: 32_768))
                    model.contextTokens = nil
                    model.outputTokens = nil
                    model.input = nil
                    model.output = nil
                    definition.models = [model]
                }
                catalog.providers.append(definition)
            }
        }
        try catalog.validate()
        if existing == nil {
            for entry in bundled { try copyCredential(entry.legacyCredentialID, entry.definition.credentialID) }
            for provider in catalog.providers where !bundled.contains(where: { $0.definition.id == provider.id }) {
                try copyCredential(provider.id, provider.credentialID)
            }
        }
        let encoded = try JSONEncoder().encode(catalog)
        defaults.set(encoded, forKey: ProviderRegistry.catalogKey)
        guard defaults.data(forKey: ProviderRegistry.catalogKey) == encoded else {
            throw StorageMigrationError.invalidApplicationStorage("provider catalog")
        }
        defaults.removeObject(forKey: ProviderRegistry.customProvidersKey)
        Log.app.info("StorageMigrator.providerCatalog migrated format=\(catalog.format) providers=\(catalog.providers.count) source=\(existing == nil ? "legacy" : "overlay")")
    }

    private static func removeWebsiteProviderOverrides(from catalog: ProviderCatalog, defaults: UserDefaults) throws {
        var next = catalog
        next.providers.removeAll { $0.api == .web }
        try next.validate()
        let removed = catalog.providers.count - next.providers.count
        guard removed > 0 else { return }
        let encoded = try JSONEncoder().encode(next)
        defaults.set(encoded, forKey: ProviderRegistry.catalogKey)
        guard defaults.data(forKey: ProviderRegistry.catalogKey) == encoded else {
            throw StorageMigrationError.invalidApplicationStorage("provider catalog")
        }
        Log.app.info("StorageMigrator.providerCatalog removedWebsiteOverrides=\(removed) providers=\(next.providers.count)")
    }
}

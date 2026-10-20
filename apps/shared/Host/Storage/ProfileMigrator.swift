import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

nonisolated enum ProfileSchema {
    static let versions = [
        "2026-06-15",
        "2026-06-26",
        "2026-07-06",
        "2026-07-10",
        "2026-07-11",
        "2026-07-12-chat",
        "2026-07-19-artifacts",
        "2026-07-27-chat-directories",
        "2026-07-29-migration-repair",
        "2026-08-01-agent-context",
        "2026-08-03-skill-namespace",
        "2026-08-10-plain-skill-names",
        "2026-08-17-runtime",
        "2026-08-29-compacted-context",
        "2026-08-31-model-selection",
        "2026-09-18-providers",
        "2026-09-20-browser-functions",
        "2026-09-24-repository-skills",
        "2026-09-25-import-memory",
        "2026-09-27-outcome-skills",
        "2026-09-28-provider-skill",
        "2026-10-05-pi-durable",
        "2026-10-10-profile-filesystem",
        "2026-10-10-workspace-binding",
        "2026-10-10-profile-files",
        "2026-10-11-public-profile-files",
        "2026-10-14-portable-profile",
        "2026-10-14-visible-profile",
        "2026-10-14-internal-profile-state",
        "2026-10-15-lazy-conversations",
        "2026-10-20-schedules",
    ]
    static var current: String { versions.last! }

    static let steps: [@Sendable (URL) throws -> Void] = [
        { _ in },
        { _ in },
        { try ProfileMigrator.moveAttachmentsToFiles(at: $0) },
        { try ProfileMigrator.migrateLegacySkills(at: $0) },
        { _ in },
        { try ProfileMigrator.renameLibraryToFiles(at: $0) },
        { try ProfileMigrator.moveConversationsIntoDirectories(at: $0) },
        { try ProfileMigrator.repairStorage(at: $0) },
        { try ProfileMigrator.migrateAgentContexts(at: $0) },
        { try ProfileMigrator.namespaceUserSkills(at: $0) },
        { try ProfileMigrator.removeUserSkillNamespace(at: $0) },
        { _ in },
        { try ProfileMigrator.removeRedundantAgentContexts(at: $0) },
        { try ProfileMigrator.migrateConversationModelSelections(at: $0) },
        { try ProfileMigrator.migrateConversationProviderDefinitions(at: $0) },
        { try ProfileMigrator.removeBrowserServiceAttachments(at: $0) },
        { try ProfileMigrator.migrateProfileSkillCatalog(at: $0) },
        { try ProfileMigrator.migrateReservedImportMemorySkill(at: $0) },
        { try ProfileMigrator.migrateReservedOutcomeSkills(at: $0) },
        { try ProfileMigrator.migrateReservedSkill("manage-providers", at: $0) },
    ]
}

nonisolated enum ProfileMigrator {
    static func recoverPublications() throws {
        try recoverDurablePublications()
        try recoverPublicProfilePublications()
    }

    static let durableProfileVersion = "2026-10-05-pi-durable"

    static let profileFilesystemVersion = "2026-10-10-profile-filesystem"

    static let fileBindingVersion = "2026-10-10-workspace-binding"

    static let filesystemProfileVersion = "2026-10-10-profile-files"

    static let internalStateVersion = "2026-10-14-internal-profile-state"

    static let schedulesVersion = "2026-10-20-schedules"

    static let lazyConversationVersion = "2026-10-15-lazy-conversations"

    static let visibleProfileVersion = "2026-10-14-visible-profile"

    static let portableProfileVersion = "2026-10-14-portable-profile"

    static let publicProfileVersion = "2026-10-11-public-profile-files"

    static let nativeProfileVersion = "2026-09-28-provider-skill"

    static func legacyWorkflowLocation(_ parts: [String]) throws -> VirtualFileSystem.Location? {
        guard parts.first == "guidance" else { return nil }
        if parts.count == 1 { return .skills }
        let names = ["evolve", "import-memory", "manage-providers", "manage-skills", "visualize"]
        guard parts.count >= 2, names.contains(parts[1]) else { throw VirtualFileSystem.Error.invalidPath(parts.joined(separator: "/")) }
        let name = parts[1]
        if parts.count == 2 { return .skill(name) }
        let path = parts.dropFirst(2).joined(separator: "/")
        if path == "guide.md" { return .skillFile(name) }
        if ["references", "scripts"].contains(path) { return .skillDirectory(name, path) }
        guard SkillFiles.isResourcePath(path) || SkillFiles.isResourcePath(path + "/file.js") else {
            throw VirtualFileSystem.Error.invalidPath(parts.joined(separator: "/"))
        }
        Log.app.info("StorageMigrator.workflowAlias from=\(parts.joined(separator: "/")) to=skills/\(name)/\(path)")
        return .skillResource(name, path)
    }
}

extension ProfileMigrator {
    private static func preparePortableProfile(_ profile: Profile, config: ProfileConfig) async throws -> Profile {
        let manager = FileManager.default
        let destination = ProfileIO.portableStateDirectory(profile.url)
        let stage = profile.url.appendingPathComponent(".ox-stage-" + profile.id.uuidString, isDirectory: true)
        if !manager.fileExists(atPath: destination.path) {
            guard profile.location == .local, config.contentDirectory == profile.name else {
                throw StorageMigrationError.invalidApplicationStorage("This folder is missing its Profile database. Open the original Profile in Ox before moving its folder.")
            }
            let source = ProfileIO.stateDirectory(profile.id)
            if !manager.fileExists(atPath: stage.path) {
                guard config.version == publicProfileVersion else { throw StorageMigrationError.invalidApplicationStorage("portable Profile publication") }
                try await validateProfileSnapshot(content: profile.url, state: source, identity: profile.id)
                let working = profile.url.appendingPathComponent(".ox-stage-copy-" + UUID().uuidString, isDirectory: true)
                _ = try await Task.detached(priority: .userInitiated) {
                    try StorageMigrationSupport.copyMigrationSource(from: source, to: working)
                }.value
                try await validateProfileSnapshot(content: profile.url, state: working, identity: profile.id)
                try syncImportedTree(working)
                try manager.moveItem(at: working, to: stage)
                try syncDurableDirectory(profile.url)
            }
            guard let staged = ProfileIO.readConfig(at: stage), staged.id == profile.id,
                  [publicProfileVersion, portableProfileVersion].contains(staged.version) else {
                throw StorageMigrationError.invalidApplicationStorage("portable Profile staging")
            }
            try await validateProfileSnapshot(content: profile.url, state: stage, identity: profile.id)
            var portable = config
            portable.version = portableProfileVersion
            portable.contentDirectory = nil
            try ProfileIO.writeConfig(portable, to: stage)
            try syncImportedTree(stage)
            var predecessor = config
            predecessor.version = portableProfileVersion
            try ProfileIO.writeConfig(predecessor, to: source)
            try syncDurableDirectory(source)
            try manager.moveItem(at: stage, to: destination)
            try syncDurableDirectory(profile.url)
            Log.app.info("StorageMigrator.portable published id=\(profile.id) predecessorStateRetained=true")
        }
        guard await materialize(at: profile.url),
              let manifest = ProfileIO.readConfig(at: profile.url), manifest.id == profile.id,
              manifest.version == portableProfileVersion,
              manager.fileExists(atPath: destination.appendingPathComponent("state.sqlite").path) else {
            throw StorageMigrationError.invalidApplicationStorage("portable Profile database")
        }
        return try await prepareVisibleProfile(profile, config: manifest)
    }

    private static func prepareVisibleProfile(_ profile: Profile, config: ProfileConfig) async throws -> Profile {
        let manager = FileManager.default
        let source = ProfileIO.portableStateDirectory(profile.url)
        if manager.fileExists(atPath: source.appendingPathComponent(ProfileIO.configName).path) {
            guard await materialize(at: profile.url) else {
                throw StorageMigrationError.invalidApplicationStorage("Profile files are not available yet")
            }
            var entries = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey])
                .filter { $0.lastPathComponent != ProfileIO.configName }
            for entry in entries + [source.appendingPathComponent(ProfileIO.configName)] {
                guard try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      !manager.fileExists(atPath: profile.url.appendingPathComponent(entry.lastPathComponent).path) else {
                    throw RuntimeError.bridge("This Profile already contains \(entry.lastPathComponent). Move that item aside in Files and open the Profile again.")
                }
            }
            if config.version == portableProfileVersion {
                try await validateProfileSnapshot(content: profile.url, state: source, identity: profile.id)
                var manifest = config
                manifest.version = visibleProfileVersion
                try ProfileIO.writeConfig(manifest, to: source)
                try syncImportedTree(source)
                entries = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey])
                    .filter { $0.lastPathComponent != ProfileIO.configName }
            }
            Log.app.info("StorageMigrator.visible start id=\(profile.id) resuming=\(config.version == visibleProfileVersion) files=\(entries.count)")
            for entry in entries {
                try manager.moveItem(at: entry, to: profile.url.appendingPathComponent(entry.lastPathComponent))
                try syncDurableDirectory(profile.url)
                try syncDurableDirectory(source)
            }
            try manager.moveItem(at: source.appendingPathComponent(ProfileIO.configName), to: profile.url.appendingPathComponent(ProfileIO.configName))
            try syncDurableDirectory(profile.url)
            Log.app.info("StorageMigrator.visible published id=\(profile.id) files=\(entries.count)")
        }
        if manager.fileExists(atPath: source.path), try manager.contentsOfDirectory(atPath: source.path).isEmpty {
            try manager.removeItem(at: source)
            try syncDurableDirectory(profile.url)
        }
        guard let manifest = ProfileIO.readConfig(at: profile.url), manifest.id == profile.id,
              manifest.version == visibleProfileVersion,
              manager.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
            throw StorageMigrationError.invalidApplicationStorage("visible Profile database")
        }
        do {
            let probe = profile.url.appendingPathComponent(".write-check-" + UUID().uuidString)
            try Data().write(to: probe, options: .withoutOverwriting)
            try manager.removeItem(at: probe)
        } catch {
            throw RuntimeError.bridge("This Profile folder must allow reading and writing. Check its permissions in Files and open it again.")
        }
        return try await prepareInternalState(profile, config: manifest)
    }

    private static func prepareInternalState(_ profile: Profile, config: ProfileConfig) async throws -> Profile {
        let manager = FileManager.default
        let destination = ProfileIO.portableStateDirectory(profile.url)
        let names = ["state.sqlite", "payloads", "staging"]
        let requiredFiles = ["state.sqlite", "state.sqlite-wal", "state.sqlite-shm", "state.sqlite-journal"]
        let paths = config.version != visibleProfileVersion
            ? requiredFiles.flatMap { [$0, ".ox/" + $0] }
            : nil
        guard await materialize(at: profile.url, paths: paths) else {
            throw StorageMigrationError.invalidApplicationStorage("Profile files are not available yet")
        }
        if manager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw StorageMigrationError.invalidApplicationStorage("Profile state directory")
            }
        }
        for name in names where manager.fileExists(atPath: profile.url.appendingPathComponent(name).path) {
            guard try profile.url.appendingPathComponent(name).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  !manager.fileExists(atPath: destination.appendingPathComponent(name).path) else {
                throw RuntimeError.bridge("This Profile already contains .ox/\(name). Move that item aside in Files and open the Profile again.")
            }
        }
        if config.version == visibleProfileVersion {
            try await validateProfileSnapshot(content: profile.url, state: profile.url, identity: profile.id)
            if !manager.fileExists(atPath: destination.path) {
                try manager.createDirectory(at: destination, withIntermediateDirectories: false)
            }
            try syncDurableDirectory(profile.url)
            var manifest = config
            manifest.version = internalStateVersion
            try ProfileIO.writeConfig(manifest, to: profile.url)
            try syncDurableDirectory(profile.url)
        }
        for name in names {
            let source = profile.url.appendingPathComponent(name)
            if manager.fileExists(atPath: source.path) {
                try manager.moveItem(at: source, to: destination.appendingPathComponent(name))
                try syncDurableDirectory(destination)
                try syncDurableDirectory(profile.url)
            }
        }
        guard manager.fileExists(atPath: destination.appendingPathComponent("state.sqlite").path) else {
            throw StorageMigrationError.invalidApplicationStorage("Profile database")
        }
        do {
            for root in [profile.url, destination] {
                let probe = root.appendingPathComponent(".write-check-" + UUID().uuidString)
                try Data().write(to: probe, options: .withoutOverwriting)
                try manager.removeItem(at: probe)
            }
        } catch {
            throw RuntimeError.bridge("This Profile folder must allow reading and writing. Check its permissions in Files and open it again.")
        }
        if config.version == visibleProfileVersion {
            Log.app.info("StorageMigrator.internalState published id=\(profile.id)")
        }
        var manifest = config
        manifest.version = schedulesVersion
        if config.version != schedulesVersion {
            try ProfileIO.writeConfig(manifest, to: profile.url)
            try syncDurableDirectory(profile.url)
        }
        var prepared = profile
        prepared.version = schedulesVersion
        return prepared
    }

    static func migrate(_ profile: Profile, progress: @Sendable @escaping (String) async -> Void = { _ in }) async throws -> Profile {
        await progress(String(localized: "Checking Profile…"))
        try recoverDurablePublications()
        try recoverPublicProfilePublications()
        guard let config = ProfileIO.readConfig(at: profile.url), config.id == profile.id, sourceVersion(for: config.version) != nil else {
            Log.app.error("StorageMigrator.reject unknown version=\(profile.version) id=\(profile.id)")
            throw StorageMigrationError.unsupportedProfileVersion(profile.name, profile.version)
        }
        var migrated = profile
        migrated.version = config.version
        if [internalStateVersion, lazyConversationVersion, schedulesVersion].contains(config.version) {
            await progress(String(localized: "Preparing Profile files…"))
            return try await prepareInternalState(migrated, config: config)
        }
        if config.version == visibleProfileVersion {
            await progress(String(localized: "Preparing portable Profile…"))
            return try await prepareVisibleProfile(migrated, config: config)
        }
        if config.version == portableProfileVersion || config.version == publicProfileVersion {
            await progress(String(localized: "Verifying Profile…"))
            return try await preparePortableProfile(migrated, config: config)
        }
        if config.version == filesystemProfileVersion {
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local filesystem Profile database")
            }
            await progress(String(localized: "Updating Profile storage…"))
            return try await migrate(try await migratePublicProfile(migrated, config: config, destination: ProfileIO.publicProfiles.appendingPathComponent(profile.name)), progress: progress)
        }
        if config.version == fileBindingVersion {
            await progress(String(localized: "Preparing Profile files…"))
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local Profile filesystem database")
            }
            try await prepareFiles(at: profile.url, profileID: profile.id)
            var manifest = config
            manifest.version = filesystemProfileVersion
            try ProfileIO.writeConfig(manifest, to: profile.url)
            try syncDurableDirectory(profile.url)
            migrated.version = filesystemProfileVersion
            return try await migrate(migrated, progress: progress)
        }
        if config.version == profileFilesystemVersion {
            await progress(String(localized: "Preparing Profile files…"))
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local Profile filesystem database")
            }
            try await prepareFiles(at: profile.url, profileID: profile.id)
            var manifest = config
            manifest.version = fileBindingVersion
            try ProfileIO.writeConfig(manifest, to: profile.url)
            try syncDurableDirectory(profile.url)
            migrated.version = fileBindingVersion
            return try await migrate(migrated, progress: progress)
        }
        if config.version == durableProfileVersion {
            await progress(String(localized: "Preparing Profile files…"))
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local Pi Profile database")
            }
            try await prepareFiles(at: profile.url, profileID: profile.id)
            var manifest = config
            manifest.version = profileFilesystemVersion
            try ProfileIO.writeConfig(manifest, to: profile.url)
            try syncDurableDirectory(profile.url)
            migrated.version = profileFilesystemVersion
            return try await migrate(migrated, progress: progress)
        }
        guard profile.location == .local else { throw StorageMigrationError.invalidApplicationStorage("Pi Profiles require an offline local import; live cloud/external database synchronization is unsupported") }
        await progress(String(localized: "Copying Profile for migration…"))
        let working = profile.url.deletingLastPathComponent().appendingPathComponent(".pi-source-work-" + UUID().uuidString)
        let inventory = try await Task.detached(priority: .userInitiated) {
            try StorageMigrationSupport.copyMigrationSource(from: profile.url, to: working)
        }.value
        var draft = migrated
        draft.url = working
        await progress(String(localized: "Updating legacy Profile…"))
        try await migrateProfile(draft)
        draft.version = nativeProfileVersion
        let destination = profile.url.deletingLastPathComponent().appendingPathComponent(".pi-stage-" + UUID().uuidString)
        await progress(String(localized: "Migrating conversations and files…"))
        let staged = try await stageDurableProfile(draft, at: destination, progress: progress)
        guard var fields = staged.objectValue, try StorageMigrationSupport.migrationSourceInventory(at: profile.url) == inventory else {
            throw StorageMigrationError.profileMigrationFailed(profile.name)
        }
        fields["sourceInventory"] = .from(inventory)
        let result = JSONValue.object(fields)
        let journalRoot = try durableJournalDirectory(profile.id)
        let backup = journalRoot.appendingPathComponent("source-" + UUID().uuidString)
        let journal: [String: Any] = ["format": 1, "phase": "prepared", "profileID": profile.id.uuidString,
            "root": profile.url.path, "stage": destination.path, "backup": backup.path, "result": result.toAny()]
        try writeDurableJournal(journal, profileID: profile.id)
        await progress(String(localized: "Publishing updated Profile…"))
        try publishDurableJournal(journal)
        do { try FileManager.default.removeItem(at: working) }
        catch { Log.app.warning("StorageMigrator.pi workingCopy cleanup deferred error=\(error.localizedDescription)") }
        migrated.version = schedulesVersion
        Log.app.info("StorageMigrator.pi activated id=\(profile.id) sourcePreserved=true")
        return try await migrate(migrated, progress: progress)
    }

    static func privatizeAbandonedProfileStages() throws {
        let manager = FileManager.default, documents = ProfileRepository.localDocuments()
        let recovery = AppStoragePaths.applicationSupport.appendingPathComponent("StorageMigration/RetainedStages", isDirectory: true)
        let prefixes = [".pi-source-work-", ".pi-stage-", ".pi-fresh-"]
        for source in try manager.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard let prefix = prefixes.first(where: { source.lastPathComponent.hasPrefix($0) }),
                  UUID(uuidString: String(source.lastPathComponent.dropFirst(prefix.count))) != nil else { continue }
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw StorageMigrationError.invalidApplicationStorage(source.path) }
            try manager.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try AppStoragePaths.excludeFromBackup(recovery)
            let destination = recovery.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            guard !manager.fileExists(atPath: destination.path) else { throw StorageMigrationError.invalidApplicationStorage(destination.path) }
            try manager.moveItem(at: source, to: destination)
            try syncDurableDirectory(recovery)
            try syncDurableDirectory(documents)
            Log.app.info("StorageMigrator.publicFiles retained abandonedStage=\(source.lastPathComponent)")
        }
    }

    private static func migrateProfile(_ profile: Profile) async throws {
        guard let sourceVersion = sourceVersion(for: profile.version),
              let from = ProfileSchema.versions.firstIndex(of: sourceVersion) else {
            throw StorageMigrationError.unsupportedProfileVersion(profile.name, profile.version)
        }
        let target = ProfileSchema.versions.firstIndex(of: nativeProfileVersion)!
        guard from < target else { return }
        let url = profile.url
        let id = profile.id
        let was = profile.version
        try await Task.detached(priority: .userInitiated) {
            let complete = await materialize(at: url)
            guard complete else {
                Log.app.warning("StorageMigrator.deferred id=\(id) version=\(was) awaiting downloads")
                throw StorageMigrationError.profileMigrationFailed(profile.name)
            }
            Log.app.info("StorageMigrator.start id=\(id) from=\(was) to=\(ProfileSchema.current)")
            for step in from..<target {
                let version = ProfileSchema.versions[step + 1]
                do {
                    try ProfileSchema.steps[step](url)
                    try stamp(version, at: url)
                } catch {
                    Log.app.error("StorageMigrator.failed id=\(id) step=\(version) error=\(error.localizedDescription)")
                    throw error
                }
            }
            Log.app.info("StorageMigrator.done id=\(id) version=\(nativeProfileVersion)")
        }.value
    }

    private static func sourceVersion(for version: String) -> String? {
        let normalized = ["2026-07-12", "2026-07-12-ids"].contains(version) ? "2026-07-11" : version
        return ProfileSchema.versions.contains(normalized) ? normalized : nil
    }

    nonisolated private static func materialize(at root: URL, paths: [String]? = nil, timeout: TimeInterval = 60) async -> Bool {
        var evicted = requestDownloads(at: root, paths: paths)
        guard evicted > 0 else { return true }
        Log.app.info("StorageMigrator.materialize waiting evicted=\(evicted) root=\(root.lastPathComponent)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            evicted = requestDownloads(at: root, paths: paths)
            if evicted == 0 { return true }
        }
        Log.app.warning("StorageMigrator.materialize timeout evicted=\(evicted) root=\(root.lastPathComponent)")
        return false
    }

    nonisolated private static func requestDownloads(at root: URL, paths: [String]?) -> Int {
        let fm = FileManager.default
        func request(_ url: URL) -> Int {
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            guard status == .notDownloaded else { return 0 }
            try? fm.startDownloadingUbiquitousItem(at: url)
            return 1
        }
        if let paths { return paths.reduce(0) { $0 + request(root.appendingPathComponent($1)) } }
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]) else { return 0 }
        var evicted = 0
        for case let url as URL in files { evicted += request(url) }
        return evicted
    }

    nonisolated private static func stamp(_ version: String, at url: URL) throws {
        guard var config = ProfileIO.readConfig(at: url) else { throw StorageMigrationError.missingConfig }
        config.version = version
        try ProfileIO.writeConfig(config, to: url)
    }
}

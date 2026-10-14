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

    private static let legacyConversationSchemaVersion = 6

    static let durableProfileVersion = "2026-10-05-pi-durable"

    static let profileFilesystemVersion = "2026-10-10-profile-filesystem"

    static let fileBindingVersion = "2026-10-10-workspace-binding"

    static let filesystemProfileVersion = "2026-10-10-profile-files"

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

    static func createFreshProfile(name: String, base: URL, unique: Bool = false) async throws -> Profile {
        let manager = FileManager.default
        let stem = ProfileRepository.cleanName(name)
        var candidate = stem
        var suffix = 2
        while manager.fileExists(atPath: base.appendingPathComponent(candidate).path) {
            guard unique else { throw ProfileError.nameExists(name) }
            candidate = "\(stem) \(suffix)"; suffix += 1
        }
        let destination = base.appendingPathComponent(candidate)
        var manifest = ProfileConfig.fresh()
        manifest.version = filesystemProfileVersion
        let stage = try durableJournalDirectory(manifest.id).appendingPathComponent("fresh-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let runtime = DurableRuntime(databaseURL: stage.appendingPathComponent("state.sqlite"), fileRoot: stage) { method, _, _ in
            throw RuntimeError.bridge("Fresh Profile installation forbids native capabilities: \(method)")
        }
        do {
            let draft: JSONValue = .object(["format": .int(1), "profileID": .string(manifest.id.uuidString),
                "documents": .array([]), "artifacts": .array([]), "conversations": .array([])])
            _ = try await runtime.command(JSONValue.object(["action": .string("installProfile"), "draft": draft]).jsonString())
            await runtime.dispose()
            try await prepareFiles(at: stage, profileID: manifest.id)
            try ProfileIO.writeConfig(manifest, to: stage)
            try syncDurableDirectory(stage)
            let profile = Profile(id: manifest.id, name: candidate, location: .local, url: stage, createdAt: manifest.createdAt, version: filesystemProfileVersion)
            return try await migratePublicProfile(profile, config: manifest, destination: destination)
        } catch {
            await runtime.dispose()
            Log.app.error("StorageMigrator.fresh failed stage=\(stage.lastPathComponent) error=\(error.localizedDescription)")
            throw error
        }
    }

    static func prepareTemporaryFiles(at root: URL, identity: UUID) async throws {
        try await prepareFiles(at: root, profileID: identity)
        try await preparePublicFiles(content: root, state: root, profileID: identity)
    }

    static func importProfile(_ backup: ProfilePackage.Backup, name: String) async throws -> Profile {
        let started = Date()
        let manager = FileManager.default
        let candidate = ProfileRepository.cleanName(name)
        guard !candidate.hasPrefix("."), candidate != ".", candidate != ".." else { throw ProfilePackage.Failure.invalid }
        let destination = ProfileIO.publicProfiles.appendingPathComponent(candidate)
        guard !manager.fileExists(atPath: destination.path) else { throw ProfileError.nameExists(candidate) }
        let id = UUID()
        Log.app.info("ProfilePackage.import staging profile=\(id) files=\(backup.files.count)")
        let journalRoot = try durableJournalDirectory(id)
        let content = journalRoot.appendingPathComponent("public-content-" + UUID().uuidString)
        try manager.createDirectory(at: ProfileIO.privateProfiles, withIntermediateDirectories: true)
        let state = ProfileIO.privateProfiles.appendingPathComponent(".public-state-" + UUID().uuidString)
        try manager.createDirectory(at: content, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var journalWritten = false
        defer {
            if !journalWritten {
                for folder in [content, state] {
                    do { try manager.removeItem(at: folder) }
                    catch { Log.app.warning("ProfilePackage.import cleanup failed error=\(error.localizedDescription)") }
                }
            }
        }
        try await Task.detached(priority: .userInitiated) { try ProfilePackage.stage(backup, content: content, state: state) }.value
        let runtime = DurableRuntime(databaseURL: state.appendingPathComponent("state.sqlite"), fileRoot: content) { _, _, _ in
            throw RuntimeError.bridge("Profile import cannot execute native capabilities")
        }
        do {
            _ = try await runtime.command(.object(["action": .string("open"), "profileID": .string(backup.manifest.profile.id.uuidString),
                "physicalFiles": .bool(true), "prepareFiles": .bool(true), "publicFiles": .bool(true)]))
            _ = try await runtime.command(.object(["action": .string("profileImportIdentity"), "identity": .string(id.uuidString)]))
            _ = try await runtime.command(.object(["action": .string("close")]))
            await runtime.dispose()
            try await validateProfileSnapshot(content: content, state: state, identity: id)
        } catch { await runtime.dispose(); throw error }
        var config = backup.manifest.profile
        config.id = id
        config.contentDirectory = candidate
        try ProfileIO.writeConfig(config, to: state)
        try await Task.detached(priority: .userInitiated) {
            try syncImportedTree(state)
            try syncImportedTree(content)
        }.value
        try syncDurableDirectory(ProfileIO.privateProfiles)
        try Task.checkCancellation()
        let journal: [String: Any] = ["format": 1, "phase": "prepared", "profileID": id.uuidString,
            "source": journalRoot.appendingPathComponent("import-source-" + id.uuidString).path,
            "destination": destination.path, "content": content.path, "state": state.path,
            "backup": journalRoot.appendingPathComponent("original-" + UUID().uuidString).path, "inventory": [String: String]()]
        journalWritten = true
        try writePublicProfileJournal(journal, profileID: id)
        try publishPublicProfileJournal(journal)
        guard let profile = ProfileIO.profile(at: destination, location: .local) else { throw ProfilePackage.Failure.invalid }
        Log.app.info("ProfilePackage.import profile=\(id) files=\(backup.files.count) seconds=\(Date().timeIntervalSince(started))")
        return profile
    }

    static func validateProfileSnapshot(content: URL, state: URL, identity: UUID) async throws {
        let runtime = DurableRuntime(databaseURL: state.appendingPathComponent("state.sqlite"), fileRoot: content) { _, _, _ in
            throw RuntimeError.bridge("Profile validation cannot execute native capabilities")
        }
        do {
            _ = try await runtime.command(.object(["action": .string("open"), "profileID": .string(identity.uuidString),
                "physicalFiles": .bool(true), "publicFiles": .bool(true)]))
            _ = try await runtime.command(.object(["action": .string("profileExportCheck")]))
            _ = try await runtime.command(.object(["action": .string("close")]))
            await runtime.dispose()
        } catch { await runtime.dispose(); throw error }
    }

    private static func syncImportedTree(_ root: URL) throws {
        var directories = [root]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw ProfilePackage.Failure.invalid
        }
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { directories.append(file); continue }
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ProfilePackage.Failure.invalid }
            let result = fsync(fd)
            Darwin.close(fd)
            guard result == 0 else { throw StorageMigrationError.invalidApplicationStorage("Profile import durability") }
        }
        for directory in directories.reversed() { try syncDurableDirectory(directory) }
    }

    private static func prepareFiles(at root: URL, profileID: UUID) async throws {
        let runtime = DurableRuntime(databaseURL: root.appendingPathComponent("state.sqlite"), fileRoot: root) { method, _, _ in
            throw RuntimeError.bridge("Profile file preparation forbids native capabilities: \(method)")
        }
        do {
            _ = try await runtime.command(.object(["action": .string("open"), "profileID": .string(profileID.uuidString),
                "artifactFiles": .bool(true), "prepareFiles": .bool(true)]))
            let result = try await runtime.command(.object(["action": .string("filesPrepare")]))
            _ = try await runtime.command(.object(["action": .string("close")]))
            await runtime.dispose()
            try syncDurableDirectory(root)
            Log.app.info("ProfileMigrator.files prepared profile=\(profileID) result=\(result.jsonString())")
        } catch {
            await runtime.dispose()
            Log.app.error("ProfileMigrator.files failed profile=\(profileID) error=\(error.localizedDescription)")
            throw error
        }
    }

    private static func preparePublicFiles(content: URL, state: URL, profileID: UUID) async throws {
        let runtime = DurableRuntime(databaseURL: state.appendingPathComponent("state.sqlite"), fileRoot: content) { method, _, _ in
            throw RuntimeError.bridge("Public files preparation forbids native capabilities: \(method)")
        }
        do {
            _ = try await runtime.command(.object(["action": .string("open"), "profileID": .string(profileID.uuidString),
                "physicalFiles": .bool(true), "prepareFiles": .bool(true), "artifactFiles": .bool(true)]))
            let result = try await runtime.command(.object(["action": .string("publicFilesPrepare"), "splitStorage": .bool(content != state)]))
            _ = try await runtime.command(.object(["action": .string("close")]))
            await runtime.dispose()
            try syncDurableDirectory(state)
            try syncDurableDirectory(content)
            Log.app.info("StorageMigrator.publicFiles prepared profile=\(profileID) result=\(result.jsonString())")
        } catch {
            await runtime.dispose()
            throw error
        }
    }

    private static func migratePublicProfile(_ profile: Profile, config: ProfileConfig, destination: URL) async throws -> Profile {
        let manager = FileManager.default
        guard destination.deletingLastPathComponent().standardizedFileURL.path == ProfileIO.publicProfiles.standardizedFileURL.path,
              !manager.fileExists(atPath: destination.path), !manager.fileExists(atPath: ProfileIO.stateDirectory(profile.id).path) else {
            throw StorageMigrationError.collision(destination.lastPathComponent)
        }
        try await prepareFiles(at: profile.url, profileID: profile.id)
        let journalRoot = try durableJournalDirectory(profile.id)
        let sourceCopy = journalRoot.appendingPathComponent("public-source-" + UUID().uuidString)
        let inventory = try await Task.detached(priority: .userInitiated) {
            try StorageMigrationSupport.copyMigrationSource(from: profile.url, to: sourceCopy)
        }.value
        let content = journalRoot.appendingPathComponent("public-content-" + UUID().uuidString)
        try manager.copyItem(at: sourceCopy, to: content)
        try manager.createDirectory(at: ProfileIO.privateProfiles, withIntermediateDirectories: true)
        try AppStoragePaths.excludeFromBackup(ProfileIO.privateProfiles)
        let state = ProfileIO.privateProfiles.appendingPathComponent(".public-state-" + UUID().uuidString)
        try manager.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["state.sqlite", "state.sqlite-wal", "state.sqlite-shm"] {
            let file = content.appendingPathComponent(name)
            if manager.fileExists(atPath: file.path) { try manager.moveItem(at: file, to: state.appendingPathComponent(name)) }
        }
        let runtime = DurableRuntime(databaseURL: state.appendingPathComponent("state.sqlite"), fileRoot: content) { method, _, _ in
            throw RuntimeError.bridge("Public file inventory forbids native capabilities: \(method)")
        }
        do {
            _ = try await runtime.command(.object(["action": .string("open"), "profileID": .string(profile.id.uuidString),
                "physicalFiles": .bool(true), "prepareFiles": .bool(true), "artifactFiles": .bool(true)]))
            let result = try await runtime.command(.object(["action": .string("publicFilesInventory")]))
            for file in result.objectValue?["files"]?.arrayValue ?? [] {
                guard let path = file.objectValue?["path"]?.stringValue, path.hasPrefix("artifacts/"), path.split(separator: "/").count == 2 else {
                    throw StorageMigrationError.invalidApplicationStorage("private file migration path")
                }
                let target = state.appendingPathComponent("payloads", isDirectory: true).appendingPathComponent(String(path.dropFirst(10)))
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try manager.moveItem(at: content.appendingPathComponent(path), to: target)
            }
            _ = try await runtime.command(.object(["action": .string("close")]))
            await runtime.dispose()
        } catch { await runtime.dispose(); throw error }
        for name in [ProfileIO.configName, ".files", ".migration-conversations"] {
            let file = content.appendingPathComponent(name)
            if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        }
        try await preparePublicFiles(content: content, state: state, profileID: profile.id)
        var manifest = config
        manifest.version = publicProfileVersion
        manifest.contentDirectory = destination.lastPathComponent
        try ProfileIO.writeConfig(manifest, to: state)
        try syncDurableDirectory(state)
        let journal: [String: Any] = ["format": 1, "phase": "prepared", "profileID": profile.id.uuidString,
            "source": profile.url.path, "destination": destination.path, "content": content.path, "state": state.path,
            "backup": journalRoot.appendingPathComponent("original-" + UUID().uuidString).path, "inventory": inventory]
        try writePublicProfileJournal(journal, profileID: profile.id)
        try publishPublicProfileJournal(journal)
        do { try manager.removeItem(at: sourceCopy) }
        catch { Log.app.warning("StorageMigrator.publicFiles sourceCopy cleanup deferred error=\(error.localizedDescription)") }
        guard let published = ProfileIO.profile(at: destination, location: .local) else { throw StorageMigrationError.profileMigrationFailed(profile.name) }
        return published
    }

    private static func writePublicProfileJournal(_ journal: [String: Any], profileID: UUID) throws {
        let root = try durableJournalDirectory(profileID)
        let file = root.appendingPathComponent("public-journal.json")
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: file, options: .atomic)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageMigrationError.invalidApplicationStorage("public Profile publication journal") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw StorageMigrationError.invalidApplicationStorage("public Profile journal durability") }
        try syncDurableDirectory(root)
    }

    private static func publishPublicProfileJournal(_ journal: [String: Any]) throws {
        guard journal["format"] as? Int == 1, let idText = journal["profileID"] as? String, let id = UUID(uuidString: idText),
              let sourcePath = journal["source"] as? String, let destinationPath = journal["destination"] as? String,
              let contentPath = journal["content"] as? String, let statePath = journal["state"] as? String,
              let backupPath = journal["backup"] as? String, let inventory = journal["inventory"] as? [String: String] else {
            throw StorageMigrationError.invalidApplicationStorage("public Profile publication journal")
        }
        let source = URL(fileURLWithPath: sourcePath), destination = URL(fileURLWithPath: destinationPath)
        let content = URL(fileURLWithPath: contentPath), state = URL(fileURLWithPath: statePath), backup = URL(fileURLWithPath: backupPath)
        let journalRoot = try durableJournalDirectory(id), target = ProfileIO.stateDirectory(id)
        guard destination.deletingLastPathComponent().standardizedFileURL.path == ProfileIO.publicProfiles.standardizedFileURL.path,
              state.deletingLastPathComponent().standardizedFileURL.path == ProfileIO.privateProfiles.standardizedFileURL.path,
              state.lastPathComponent.hasPrefix(".public-state-"), content.deletingLastPathComponent().path == journalRoot.path,
              content.lastPathComponent.hasPrefix("public-content-"), backup.deletingLastPathComponent().path == journalRoot.path,
              backup.lastPathComponent.hasPrefix("original-"), [ProfileRepository.localDocuments(), ProfileIO.publicProfiles, journalRoot].map(\.path).contains(source.deletingLastPathComponent().path) else {
            throw StorageMigrationError.invalidApplicationStorage("public Profile publication paths")
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: source.path) {
            guard !manager.fileExists(atPath: backup.path), try StorageMigrationSupport.migrationSourceInventory(at: source) == inventory else { throw StorageMigrationError.collision(source.lastPathComponent) }
            try manager.moveItem(at: source, to: backup)
            try syncDurableDirectory(source.deletingLastPathComponent())
            try syncDurableDirectory(journalRoot)
        }
        if manager.fileExists(atPath: state.path) {
            guard !manager.fileExists(atPath: target.path), let config = ProfileIO.readConfig(at: state), config.id == id,
                  config.version == publicProfileVersion, config.contentDirectory == destination.lastPathComponent else {
                throw StorageMigrationError.collision(target.lastPathComponent)
            }
            try manager.moveItem(at: state, to: target)
            try syncDurableDirectory(ProfileIO.privateProfiles)
        } else {
            guard let config = ProfileIO.readPrivateConfig(id), config.version == publicProfileVersion,
                  config.contentDirectory == destination.lastPathComponent else { throw StorageMigrationError.invalidApplicationStorage("published private Profile") }
        }
        try manager.createDirectory(at: ProfileIO.publicProfiles, withIntermediateDirectories: true)
        try AppStoragePaths.excludeFromBackup(ProfileIO.publicProfiles)
        if manager.fileExists(atPath: content.path) {
            guard !manager.fileExists(atPath: destination.path) else { throw StorageMigrationError.collision(destination.lastPathComponent) }
            try manager.moveItem(at: content, to: destination)
            try syncDurableDirectory(ProfileIO.publicProfiles)
        } else if !manager.fileExists(atPath: destination.path) { throw StorageMigrationError.invalidApplicationStorage("published Profile content") }
        var published = journal; published["phase"] = "published"
        try writePublicProfileJournal(published, profileID: id)
        Log.app.info("StorageMigrator.publicFiles published id=\(id) from=\(filesystemProfileVersion) to=\(publicProfileVersion) sourceBackupRetained=true")
    }

    private static func recoverPublicProfilePublications() throws {
        let base = AppStoragePaths.applicationSupport.appendingPathComponent("StorageMigration/PiProfiles")
        guard FileManager.default.fileExists(atPath: base.path) else { return }
        for root in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            let file = root.appendingPathComponent("public-journal.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                throw StorageMigrationError.invalidApplicationStorage("public Profile recovery journal")
            }
            if journal["phase"] as? String == "prepared" { try publishPublicProfileJournal(journal) }
            else if journal["phase"] as? String != "published" { throw StorageMigrationError.invalidApplicationStorage("public Profile recovery phase") }
        }
    }

    private static func durableJournalDirectory(_ id: UUID) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("StorageMigration/PiProfiles/" + id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private static func writeDurableJournal(_ journal: [String: Any], profileID: UUID) throws {
        let directory = try durableJournalDirectory(profileID)
        let file = directory.appendingPathComponent("journal.json")
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: file, options: .atomic)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration journal") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration journal durability") }
        try syncDurableDirectory(directory)
    }

    private static func syncDurableDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration directory") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration directory durability") }
    }

    private static func publishDurableJournal(_ journal: [String: Any]) throws {
        guard journal["format"] as? Int == 1, let text = journal["profileID"] as? String, let id = UUID(uuidString: text),
              let rootPath = journal["root"] as? String, let stagePath = journal["stage"] as? String, let backupPath = journal["backup"] as? String else {
            throw StorageMigrationError.invalidApplicationStorage("Pi migration journal")
        }
        let root = URL(fileURLWithPath: rootPath), stage = URL(fileURLWithPath: stagePath), backup = URL(fileURLWithPath: backupPath)
        guard stage.deletingLastPathComponent() == root.deletingLastPathComponent(), stage.lastPathComponent.hasPrefix(".pi-stage-"),
              backup.deletingLastPathComponent() == (try durableJournalDirectory(id)), root != stage, root != backup else {
            throw StorageMigrationError.invalidApplicationStorage("Pi migration publication paths")
        }
        if let manifest = ProfileIO.readConfig(at: root), manifest.id == id, manifest.version == durableProfileVersion {
            var published = journal; published["phase"] = "published"
            try writeDurableJournal(published, profileID: id)
            return
        }
        guard let manifest = ProfileIO.readConfig(at: stage), manifest.id == id, manifest.version == durableProfileVersion,
              FileManager.default.fileExists(atPath: stage.appendingPathComponent("state.sqlite").path) else {
            throw StorageMigrationError.invalidApplicationStorage("validated staged Pi Profile")
        }
        if FileManager.default.fileExists(atPath: root.path) {
            guard !FileManager.default.fileExists(atPath: backup.path),
                  let result = journal["result"] as? [String: Any], let inventory = result["sourceInventory"] as? [String: String],
                  try StorageMigrationSupport.migrationSourceInventory(at: root) == inventory else { throw StorageMigrationError.profileMigrationFailed(root.lastPathComponent) }
            try FileManager.default.moveItem(at: root, to: backup)
            try syncDurableDirectory(root.deletingLastPathComponent())
            try syncDurableDirectory(backup.deletingLastPathComponent())
        }
        try FileManager.default.moveItem(at: stage, to: root)
        try syncDurableDirectory(root.deletingLastPathComponent())
        var published = journal; published["phase"] = "published"
        try writeDurableJournal(published, profileID: id)
        Log.app.info("StorageMigrator.pi published id=\(id) sourceBackupRetained=true")
    }

    private static func recoverDurablePublications() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("StorageMigration/PiProfiles")
        guard FileManager.default.fileExists(atPath: base.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            let file = directory.appendingPathComponent("journal.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], journal["format"] as? Int == 1 else {
                throw StorageMigrationError.invalidApplicationStorage("Pi migration journal")
            }
            if journal["phase"] as? String == "prepared" { try publishDurableJournal(journal) }
            else if journal["phase"] as? String != "published" { throw StorageMigrationError.invalidApplicationStorage("Pi migration phase") }
        }
    }

    static func durableConversationReference(for legacyID: UUID, in scope: ProfileScope) throws -> DurableConversationReference? {
        guard let id = scope.profileID else { return nil }
        let file = try durableJournalDirectory(id).appendingPathComponent("journal.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], journal["format"] as? Int == 1,
              let result = journal["result"] as? [String: Any], let installation = result["installation"] as? [String: Any],
              let conversations = installation["conversations"] as? [[String: Any]] else { throw StorageMigrationError.invalidApplicationStorage("Pi conversion results") }
        guard let record = conversations.first(where: { ($0["key"] as? String).flatMap(UUID.init(uuidString:)) == legacyID }),
              let reference = record["reference"] as? [String: Any] else { return nil }
        let value = try JSONDecoder().decode(DurableConversationReference.self, from: JSONSerialization.data(withJSONObject: reference))
        guard value.profileID == id else { throw StorageMigrationError.invalidApplicationStorage("Pi conversion identity") }
        return value
    }

    static func stageDurableProfile(_ profile: Profile, at destination: URL) async throws -> JSONValue {
        let sourcePath = profile.url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        guard profile.location == .local, profile.version == nativeProfileVersion,
              sourcePath != destinationPath, !destinationPath.hasPrefix(sourcePath + "/"), !sourcePath.hasPrefix(destinationPath + "/") else {
            throw StorageMigrationError.profileMigrationFailed(profile.name)
        }
        let prepared = try await Task.detached(priority: .userInitiated) {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw StorageMigrationError.collision(destination.lastPathComponent)
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            return try durableProfileDraft(profile, destination: destination)
        }.value
        let runtime = DurableRuntime(databaseURL: destination.appendingPathComponent("state.sqlite"), fileRoot: destination) { method, params, _ in
            guard method == "profileInstallConversation", let index = params.objectValue?["index"]?.intValue,
                  (0..<prepared.conversationCount).contains(index) else {
                throw StorageMigrationError.invalidApplicationStorage("staged conversation request")
            }
            return try await Task.detached(priority: .userInitiated) {
                let data = try durableSourceFile("\(index).json", at: prepared.conversationDirectory)
                Log.app.info("StorageMigrator.pi installing conversation=\(index + 1)/\(prepared.conversationCount) bytes=\(data.count)")
                return try JSONDecoder().decode(JSONValue.self, from: data)
            }.value
        }
        do {
            let result = try await runtime.command(JSONValue.object(["action": .string("installProfile"), "draft": prepared.draft,
                "conversationCount": .int(prepared.conversationCount)]).jsonString())
            await runtime.dispose()
            try await Task.detached(priority: .userInitiated) {
                let current = try durableSourceInventory(at: profile.url)
                guard current == prepared.inventory else { throw StorageMigrationError.profileMigrationFailed(profile.name) }
                try FileManager.default.removeItem(at: prepared.conversationDirectory)
                var manifest = prepared.manifest
                manifest["version"] = durableProfileVersion
                try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
                    .write(to: destination.appendingPathComponent(ProfileIO.configName), options: .atomic)
                let directory = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw StorageMigrationError.invalidApplicationStorage("staged Profile") }
                defer { Darwin.close(directory) }
                let file = openat(directory, ProfileIO.configName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard file >= 0 else { throw StorageMigrationError.missingConfig }
                defer { Darwin.close(file) }
                guard fsync(file) == 0, fsync(directory) == 0 else { throw StorageMigrationError.profileMigrationFailed(profile.name) }
            }.value
            Log.app.info("StorageMigrator.pi staged id=\(profile.id) target=\(durableProfileVersion) activated=false")
            return .object(["installation": try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)),
                "sourceInventory": .from(prepared.inventory), "profileID": .string(profile.id.uuidString)])
        } catch {
            await runtime.dispose()
            Log.app.error("StorageMigrator.pi stage failed id=\(profile.id) sourcePreserved=true error=\(error.localizedDescription)")
            throw error
        }
    }

    private struct DurableProfileDraft: @unchecked Sendable {
        let draft: JSONValue
        let manifest: [String: Any]
        let inventory: [String: String]
        let conversationDirectory: URL
        let conversationCount: Int
    }

    private static func durableProfileDraft(_ profile: Profile, destination: URL) throws -> DurableProfileDraft {
        let manager = FileManager.default
        let inventory = try durableSourceInventory(at: profile.url)
        let manifest = try JSONSerialization.jsonObject(with: durableSourceFile(ProfileIO.configName, at: profile.url)) as? [String: Any]
        guard let manifest, (manifest["id"] as? String).flatMap(UUID.init(uuidString:)) == profile.id,
              manifest["version"] as? String == nativeProfileVersion else { throw StorageMigrationError.missingConfig }
        let scope = ProfileScope(profileID: profile.id, root: profile.url, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        decoder.userInfo[.artifactDirectoryListing] = FileDirectoryListing()
        var documents: [[String: Any]] = []
        var artifacts: [[String: Any]] = []
        let conversationDirectory = destination.appendingPathComponent(".migration-conversations", isDirectory: true)
        try manager.createDirectory(at: conversationDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var payloads: [String: JSONValue] = [:]
        let payloadStore = DurableFileStore(root: destination)
        defer { payloadStore.close() }
        func archive(_ data: Data) throws -> JSONValue {
            let writer = try payloadStore.payloadWriter()
            try writer.append(data)
            let source = try writer.finish()
            payloads[source.objectValue!["path"]!.stringValue!] = source
            return source
        }
        let savedPath = "artifacts/.saved.json"
        let saved = inventory[savedPath] == nil ? [] : try decoder.decode([String].self, from: durableSourceFile(savedPath, at: profile.url))
        let artifactDirectory = destination.appendingPathComponent("artifacts", isDirectory: true)
        try manager.createDirectory(at: artifactDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for path in inventory.keys.sorted() {
            if ["MEMORY.md", "SOUL.md", "skill-selections.json"].contains(path) || path.hasPrefix("skills/") {
                let data = try durableSourceFile(path, at: profile.url)
                if path == "skill-selections.json", try decoder.decode(SkillSelections.self, from: data).version != 1 { throw SkillError.invalidPackage }
                guard let text = String(data: data, encoding: .utf8) else { throw StorageMigrationError.invalidApplicationStorage(path) }
                documents.append(["path": path, "text": text])
            } else if path.hasPrefix("artifacts/"), path != savedPath {
                let name = String(path.dropFirst("artifacts/".count))
                guard !name.contains("/"), try FileStore.validatedFilename(name) == name else { throw StorageMigrationError.invalidFile(path) }
                let data = try durableSourceFile(path, at: profile.url, limit: 32 * 1024 * 1024)
                let binary = data.count > 200 * 1024 || String(data: data, encoding: .utf8) == nil
                try data.write(to: artifactDirectory.appendingPathComponent(name), options: .withoutOverwriting)
                artifacts.append(["path": path, "size": data.count, "sha256": durableDigest(data), "binary": binary,
                    "saved": saved.contains { $0.caseInsensitiveCompare(name) == .orderedSame }])
            }
        }
        let names = Set(artifacts.compactMap { $0["path"] as? String }.map { String($0.dropFirst("artifacts/".count)).lowercased() })
        guard saved.allSatisfy({ names.contains($0.lowercased()) }) else { throw StorageMigrationError.invalidFile(savedPath) }
        let conversationFiles = inventory.keys.filter { $0.hasPrefix("chats/") }
        guard conversationFiles.allSatisfy({ path in
            let parts = path.split(separator: "/")
            return parts.count == 3 && UUID(uuidString: String(parts[1])) != nil && inventory["\(parts[0])/\(parts[1])/conversation.json"] != nil
        }) else { throw StorageMigrationError.invalidApplicationStorage("chats") }
        let conversationPaths = conversationFiles.filter { $0.hasSuffix("/chat.json") }.sorted()
        for (ordinal, path) in conversationPaths.enumerated() {
            try autoreleasepool {
                let prefix = String(path.dropLast("chat.json".count))
                let data = try durableSourceFile(path, at: profile.url)
                let metadata = try decodeMigrationValue(ConversationMeta.self, from: data, decoder: decoder, path: path)
                guard metadata.schemaVersion == ConversationFormat.currentSchemaVersion,
                      UUID(uuidString: String(prefix.split(separator: "/")[1])) == metadata.id else {
                    throw StorageMigrationError.invalidApplicationStorage(path)
                }
                let transcriptPath = prefix + "turns.jsonl"
                var records: [(turn: Turn, source: JSONValue, missingPurposes: Set<UUID>)] = []
                if inventory[transcriptPath] != nil {
                    let descriptor = try StorageMigrationSupport.durableSourceDescriptor(transcriptPath, at: profile.url)
                    defer { Darwin.close(descriptor) }
                    let reader = DurableTranscriptReader(descriptor: descriptor, store: payloadStore)
                    while let record = try reader.next() {
                        var missingPurposes: Set<UUID> = []
                        let value = mapMigrationInvocations(in: record.value) { invocation in
                            var invocation = invocation
                            if invocation["purpose"] == nil {
                                invocation["purpose"] = .string("")
                                if let id = invocation["id"]?.stringValue.flatMap(UUID.init(uuidString:)) { missingPurposes.insert(id) }
                            }
                            return invocation
                        }
                        let turn = try decodeMigrationValue(Turn.self, from: Data(value.jsonString().utf8), decoder: decoder,
                            path: "\(transcriptPath):\(records.count + 1)")
                        records.append((turn, record.source, missingPurposes))
                        payloads[record.source.objectValue!["path"]!.stringValue!] = record.source
                    }
                    let missingPurposes = records.reduce(0) { $0 + $1.missingPurposes.count }
                    Log.app.info("StorageMigrator.pi transcript archived path=\(transcriptPath) turns=\(records.count) externalized=\(reader.externalized) legacyPurposes=\(missingPurposes) bytes=\(reader.position)")
                }
                let turns = records.map(\.turn)
                var document = ConversationDocument(turns: turns)
                guard document.turns.map(\.id) == turns.map(\.id) else { throw StorageMigrationError.invalidApplicationStorage(transcriptPath) }
                document.apply(.sealAllTurns)
                let sealed = document.turns
                let contextPath = prefix + "context.json"
                let checkpoint = inventory[contextPath] == nil ? nil : try decodeMigrationValue(AgentContextCheckpoint.self,
                    from: durableSourceFile(contextPath, at: profile.url), decoder: decoder, path: contextPath)
                let boundary = try checkpoint.map {
                    let original = try decoder.decode(JSONValue.self, from: durableSourceFile(contextPath, at: profile.url))
                    return try durableCheckpointBoundary($0, records: records, originalMessages: original.objectValue?["messages"], store: payloadStore)
                } ?? nil
                if checkpoint != nil, boundary == nil {
                    Log.app.warning("StorageMigrator.pi context recovered path=\(contextPath) reason=staleTranscriptCheckpoint source=completeTranscript turns=\(turns.count)")
                } else if turns.requiresContextCheckpoint, checkpoint == nil {
                    Log.app.warning("StorageMigrator.pi context recovered path=\(contextPath) reason=missingCheckpoint source=completeTranscript turns=\(turns.count)")
                }
                let alias = "ox-native:\(metadata.id.uuidString)"
                var unavailableAttachments = 0
                func messages(_ source: [Message]) -> [JSONValue] {
                    source.map { message in
                        var fields = DurableMessageCodec.message(message, provider: alias, profileID: profile.id).objectValue!
                        fields["content"] = .array((fields["content"]?.arrayValue ?? []).map { block in
                            guard let name = block.objectValue?["oxAttachment"]?.stringValue,
                                  !names.contains(name.lowercased()) else { return block }
                            unavailableAttachments += 1
                            return .object(["type": .string("text"), "text": .string("[Unavailable historical attachment: artifacts/\(name)]")])
                        })
                        return .object(fields)
                    }
                }
                var entries: [[String: Any]] = [["kind": "ox.native.metadata", "data": ["source": try archive(data).toAny()]]]
                if checkpoint != nil, boundary == nil {
                    entries.append(["kind": "ox.native.context", "data": ["source": try archive(durableSourceFile(contextPath, at: profile.url)).toAny()]])
                }
                var expected: [Any] = []
                for (index, turn) in sealed.enumerated() {
                    let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(turn))
                    let model = messages(ConversationProjection.makeWireMessages(from: [turn])).map { $0.toAny() }
                    expected.append(contentsOf: model)
                    entries.append(["kind": "ox.native.turn", "model": model, "data": ["turn": canonical, "source": records[index].source.toAny()]])
                    if index == boundary, let checkpoint {
                        expected = messages(checkpoint.messages).map { $0.toAny() }
                        let source = try archive(durableSourceFile(contextPath, at: profile.url))
                        entries.append(["kind": "pi.reset", "head": "self", "data": ["source": source.toAny()], "model": expected])
                    }
                }
                if unavailableAttachments > 0 {
                    Log.app.warning("StorageMigrator.pi attachments unavailable path=\(path) count=\(unavailableAttachments) sourcePreserved=true")
                }
                var applicationMetadata = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                for key in ["id", "model", "title", "isFavorite", "hasUnreadResponse"] { applicationMetadata.removeValue(forKey: key) }
                var agent: [String: Any] = [:]
                if let model = metadata.model {
                    agent["model"] = ["provider": model.providerID, "modelId": model.modelID]
                    if let effort = model.reasoningEffort {
                        if ["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) { agent["thinkingLevel"] = effort }
                        else { applicationMetadata["nativeReasoningEffort"] = effort }
                    }
                }
                let conversation: [String: Any] = ["key": metadata.id.uuidString, "title": metadata.title ?? "", "favorite": metadata.isFavorite,
                    "unread": metadata.hasUnreadResponse, "agent": agent, "metadata": applicationMetadata, "entries": entries, "expectedContext": try durableExpectedContext(expected)]
                let encoded = try JSONSerialization.data(withJSONObject: conversation, options: [.sortedKeys])
                try encoded.write(to: conversationDirectory.appendingPathComponent("\(ordinal).json"), options: .withoutOverwriting)
                Log.app.info("StorageMigrator.pi conversation staged ordinal=\(ordinal + 1)/\(conversationPaths.count) bytes=\(encoded.count)")
            }
        }
        return DurableProfileDraft(draft: .from(["format": 1, "profileID": profile.id.uuidString, "documents": documents,
            "artifacts": artifacts, "payloads": payloads.values.map { $0.toAny() }, "conversations": []]), manifest: manifest, inventory: inventory,
            conversationDirectory: conversationDirectory, conversationCount: conversationPaths.count)
    }

    private static func decodeMigrationValue<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder, path: String) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch let error as DecodingError {
            let context: DecodingError.Context
            let reason: String
            switch error {
            case .keyNotFound(let key, let detail): context = detail; reason = "missingKey:\(key.stringValue)"
            case .valueNotFound(_, let detail): context = detail; reason = "missingValue"
            case .typeMismatch(_, let detail): context = detail; reason = "typeMismatch"
            case .dataCorrupted(let detail): context = detail; reason = "dataCorrupted"
            @unknown default: throw error
            }
            let field = String(context.codingPath.map(\.stringValue).joined(separator: ".").prefix(512))
            Log.app.error("StorageMigrator.pi decode failed path=\(path) field=\(field) reason=\(reason) sourcePreserved=true")
            throw error
        }
    }

    private static func mapMigrationInvocations(in value: JSONValue, transform: ([String: JSONValue]) -> [String: JSONValue]) -> JSONValue {
        guard var root = value.objectValue, root["type"] == .string("agent"),
              var agent = root["agent"]?.objectValue, let steps = agent["steps"]?.arrayValue else { return value }
        agent["steps"] = .array(steps.map { value in
            guard var step = value.objectValue, step["type"] == .string("action"),
                  var action = step["action"]?.objectValue, action["type"] == .string("execute"),
                  var execution = action["execute"]?.objectValue, let effects = execution["effects"]?.arrayValue else { return value }
            execution["effects"] = .array(effects.compactMap { value in
                guard var effect = value.objectValue else { return value }
                if ["step", "widget", "media"].contains(effect["type"]?.stringValue ?? ""),
                   let fields = value.toAny() as? [String: Any] {
                    guard let legacy = canonicalLegacyEffect(fields) else { return nil }
                    effect = JSONValue.from(legacy).objectValue!
                }
                if effect["type"] == .string("invocation"), let invocation = effect["invocation"]?.objectValue {
                    effect["invocation"] = .object(transform(invocation))
                }
                return .object(effect)
            })
            action["execute"] = .object(execution)
            step["action"] = .object(action)
            return .object(step)
        })
        root["agent"] = .object(agent)
        return .object(root)
    }

    private static func durableCheckpointBoundary(_ checkpoint: AgentContextCheckpoint,
        records: [(turn: Turn, source: JSONValue, missingPurposes: Set<UUID>)], originalMessages: JSONValue?, store: DurableFileStore) throws -> Int? {
        let turns = records.map(\.turn)
        if let boundary = checkpoint.boundary(in: turns) { return boundary }
        guard checkpoint.schemaVersion == AgentContextCheckpoint.currentSchemaVersion,
              let boundary = turns.firstIndex(where: { $0.id == checkpoint.throughTurnID }) else {
            throw StorageMigrationError.invalidApplicationStorage("compaction checkpoint boundary")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let currentMessagesDigest = durableDigest(try encoder.encode(checkpoint.messages))
        let originalMessagesDigest = try originalMessages.map { durableDigest(try encoder.encode($0)) }
        guard currentMessagesDigest == checkpoint.messagesDigest || originalMessagesDigest == checkpoint.messagesDigest else {
            Log.app.error("StorageMigrator.pi checkpoint invalid component=messages turn=\(checkpoint.throughTurnID.rawValue)")
            throw StorageMigrationError.invalidApplicationStorage("compaction checkpoint messages")
        }
        var hash = SHA256()
        func append(_ value: JSONValue) throws {
            if let fields = value.objectValue, let reference = fields["oxPayload"]?.objectValue, reference["format"] == .int(1),
               let source = reference["source"], let offset = reference["offset"]?.intValue, let length = reference["length"]?.intValue {
                let original = try store.capturePayload(source, offset: offset, length: length)
                let decoded = try JSONDecoder().decode(JSONValue.self, from: original)
                hash.update(data: try encoder.encode(decoded))
                return
            }
            switch value {
            case .array(let values):
                hash.update(data: Data("[".utf8))
                for (index, item) in values.enumerated() {
                    if index > 0 { hash.update(data: Data(",".utf8)) }
                    try append(item)
                }
                hash.update(data: Data("]".utf8))
            case .object(let fields):
                hash.update(data: Data("{".utf8))
                for (index, key) in fields.keys.sorted().enumerated() {
                    if index > 0 { hash.update(data: Data(",".utf8)) }
                    hash.update(data: try encoder.encode(key))
                    hash.update(data: Data(":".utf8))
                    try append(fields[key]!)
                }
                hash.update(data: Data("}".utf8))
            default: hash.update(data: try encoder.encode(value))
            }
        }
        hash.update(data: Data("[".utf8))
        for (index, record) in records[...boundary].enumerated() {
            if index > 0 { hash.update(data: Data(",".utf8)) }
            let canonical = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(record.turn))
            let original = mapMigrationInvocations(in: canonical) { invocation in
                var invocation = invocation
                if let id = invocation["id"]?.stringValue.flatMap(UUID.init(uuidString:)), record.missingPurposes.contains(id) {
                    invocation.removeValue(forKey: "purpose")
                }
                return invocation
            }
            try append(original)
        }
        hash.update(data: Data("]".utf8))
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == checkpoint.transcriptPrefixDigest else {
            Log.app.warning("StorageMigrator.pi checkpoint stale component=transcript turn=\(checkpoint.throughTurnID.rawValue)")
            return nil
        }
        return boundary
    }

    private static func durableExpectedContext(_ source: [Any]) throws -> [[String: Any]] {
        let messages = try source.map { value -> [String: Any] in
            guard let message = value as? [String: Any] else { throw StorageMigrationError.invalidApplicationStorage("model context") }
            return message
        }.filter { $0["role"] as? String != "assistant" || !["aborted", "error", "deferred"].contains($0["stopReason"] as? String ?? "") }
        var ordered: [[String: Any]] = []
        for (index, message) in messages.enumerated() {
            if message["role"] as? String == "toolResult" { continue }
            ordered.append(message)
            guard message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] else { continue }
            var results: [String: [String: Any]] = [:]
            for candidate in messages.dropFirst(index + 1) {
                if candidate["role"] as? String == "assistant" { break }
                if candidate["role"] as? String == "toolResult", let id = candidate["toolCallId"] as? String, results[id] == nil { results[id] = candidate }
            }
            for call in content where call["type"] as? String == "toolCall" {
                guard let id = call["id"] as? String, let name = call["name"] as? String, let timestamp = message["timestamp"] else {
                    throw StorageMigrationError.invalidApplicationStorage("tool context")
                }
                ordered.append(results[id] ?? ["role": "toolResult", "toolCallId": id, "toolName": name,
                    "content": [["type": "text", "text": "Tool result unavailable: history ends before this call completed."]],
                    "isError": true, "details": ["reason": "missing_result"], "timestamp": timestamp])
            }
        }
        return ordered
    }

    private static func durableSourceInventory(at root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        var directories = [(root, "")]
        while let (directory, prefix) = directories.popLast() {
            for url in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw StorageMigrationError.invalidApplicationStorage(url.lastPathComponent) }
                let path = prefix + url.lastPathComponent
                if values.isDirectory == true {
                    guard ["chats", "skills", "artifacts"].contains(path) || path.hasPrefix("chats/") || path.hasPrefix("skills/") else {
                        throw StorageMigrationError.invalidApplicationStorage(path)
                    }
                    directories.append((url, path + "/")); continue
                }
                guard values.isRegularFile == true,
                    [ProfileIO.configName, "MEMORY.md", "SOUL.md", "skill-selections.json", "artifacts/.saved.json"].contains(path)
                    || path.hasPrefix("skills/") || path.hasPrefix("artifacts/")
                    || (path.hasPrefix("chats/") && ["chat.json", "turns.jsonl", "context.json"].contains(url.lastPathComponent)) else {
                    throw StorageMigrationError.invalidApplicationStorage(path)
                }
                files[path] = try StorageMigrationSupport.durableSourceFingerprint(path, at: root)
            }
        }
        return files
    }

    private static func durableSourceFile(_ path: String, at root: URL, limit: Int = 64 * 1024 * 1024) throws -> Data {
        let descriptor = try StorageMigrationSupport.durableSourceDescriptor(path, at: root)
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_size <= limit else {
            Log.app.error("StorageMigrator.pi source too large path=\(path) bytes=\(before.st_size) limit=\(limit)")
            throw StorageMigrationError.invalidApplicationStorage(path)
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, output.count + count <= limit else { throw StorageMigrationError.invalidApplicationStorage(path) }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size, output.count == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw StorageMigrationError.invalidApplicationStorage(path)
        }
        return output
    }

    private final class DurableTranscriptReader {
        private let descriptor: Int32
        private let store: DurableFileStore
        private var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        private var count = 0
        private var index = 0
        private var archived = 0
        private var writer: DurablePayloadWriter?
        private var recordStart = 0
        private var captures: [[String]: (offset: Int, length: Int)] = [:]
        private(set) var position = 0
        private(set) var externalized = 0

        init(descriptor: Int32, store: DurableFileStore) {
            self.descriptor = descriptor
            self.store = store
        }

        func next() throws -> (value: JSONValue, source: JSONValue)? {
            while let byte = try peek(), byte == 10 || byte == 13 { advance() }
            guard try peek() != nil else { return nil }
            recordStart = position
            captures.removeAll(keepingCapacity: true)
            writer = try store.payloadWriter()
            archived = index
            let value = try parse(path: [], build: true, depth: 0)
            try spaces()
            guard let value, try peek() == nil || peek() == 10 else { throw invalid() }
            try flush()
            let source = try writer!.finish()
            writer = nil
            return (bind(value, source: source), source)
        }

        private func bind(_ value: JSONValue, path: [String] = [], source: JSONValue) -> JSONValue {
            if let capture = captures[path] {
                return .object([
                    "oxPayload": .object(["format": .int(1), "source": source, "offset": .int(capture.offset), "length": .int(capture.length)]),
                    "preview": .string("Large historical value omitted from model context."),
                ])
            }
            switch value {
            case .array(let values): return .array(values.enumerated().map { bind($0.element, path: path + [String($0.offset)], source: source) })
            case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, bind($0.value, path: path + [$0.key], source: source)) }))
            default: return value
            }
        }

        private func parse(path: [String], build: Bool, depth: Int) throws -> JSONValue? {
            guard depth <= 128 else { throw invalid() }
            try spaces()
            if build, path.suffix(4) == ["invocation", "outcome", "succeeded", "_0"] || path.suffix(2) == ["invocation", "args"] {
                let start = position - recordStart
                _ = try parse(path: path, build: false, depth: depth)
                let length = position - recordStart - start
                try flush()
                if length <= DurablePayloadWriter.inlineLimit {
                    return try JSONDecoder().decode(JSONValue.self, from: writer!.read(offset: start, length: length))
                }
                externalized += 1
                captures[path] = (start, length)
                return .null
            }
            guard let byte = try peek() else { throw invalid() }
            if byte == 123 {
                advance()
                var fields: [String: JSONValue] = [:]
                var keys = Set<String>()
                try spaces()
                if try peek() == 125 { advance(); return build ? .object(fields) : nil }
                while true {
                    guard try peek() == 34 else { throw invalid() }
                    let data = try string(collect: true)
                    let key = try JSONDecoder().decode(String.self, from: data!)
                    guard keys.insert(key).inserted else { throw invalid() }
                    try spaces()
                    try expect(58)
                    let value = try parse(path: build ? path + [key] : [], build: build, depth: depth + 1)
                    if let value { fields[key] = value }
                    try spaces()
                    if try peek() == 125 { advance(); break }
                    try expect(44)
                    try spaces()
                }
                return build ? .object(fields) : nil
            }
            if byte == 91 {
                advance()
                var values: [JSONValue] = []
                var ordinal = 0
                try spaces()
                if try peek() == 93 { advance(); return build ? .array(values) : nil }
                while true {
                    if let value = try parse(path: build ? path + [String(ordinal)] : [], build: build, depth: depth + 1) { values.append(value) }
                    ordinal += 1
                    try spaces()
                    if try peek() == 93 { advance(); break }
                    try expect(44)
                }
                return build ? .array(values) : nil
            }
            if byte == 34 {
                let data = try string(collect: build)
                return try data.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
            }
            var token = Data()
            while let byte = try peek(), ![9, 10, 13, 32, 44, 93, 125].contains(byte) {
                guard token.count < 1024 else { throw invalid() }
                token.append(byte)
                advance()
            }
            let value = try JSONDecoder().decode(JSONValue.self, from: token)
            return build ? value : nil
        }

        private func string(collect: Bool) throws -> Data? {
            try expect(34)
            var token: Data? = collect ? Data([34]) : nil
            var remaining = 0
            var lower: UInt8 = 0x80
            var upper: UInt8 = 0xbf
            while true {
                guard try peek() != nil else { throw invalid() }
                let start = index
                while index < count {
                    let byte = buffer[index]
                    if byte == 34 || byte == 92 || byte < 32 { break }
                    if remaining > 0 {
                        guard byte >= lower, byte <= upper else { throw invalid() }
                        remaining -= 1
                        lower = 0x80; upper = 0xbf
                    } else if byte >= 0x80 {
                        switch byte {
                        case 0xc2...0xdf: remaining = 1
                        case 0xe0: remaining = 2; lower = 0xa0
                        case 0xe1...0xec, 0xee...0xef: remaining = 2
                        case 0xed: remaining = 2; upper = 0x9f
                        case 0xf0: remaining = 3; lower = 0x90
                        case 0xf1...0xf3: remaining = 3
                        case 0xf4: remaining = 3; upper = 0x8f
                        default: throw invalid()
                        }
                    }
                    index += 1; position += 1
                }
                if collect {
                    token!.append(contentsOf: buffer[start..<index])
                    guard token!.count <= 64 * 1024 * 1024 else { throw invalid() }
                }
                guard let byte = try peek() else { throw invalid() }
                if byte == 34 {
                    guard remaining == 0 else { throw invalid() }
                    advance()
                    token?.append(34)
                    return token
                }
                if byte == 92 {
                    guard remaining == 0 else { throw invalid() }
                    advance()
                    token?.append(92)
                    guard let escape = try peek(), [34, 47, 92, 98, 102, 110, 114, 116, 117].contains(escape) else { throw invalid() }
                    advance()
                    token?.append(escape)
                    if escape == 117 {
                        for _ in 0..<4 {
                            guard let hex = try peek(), (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw invalid() }
                            advance()
                            token?.append(hex)
                        }
                    }
                } else if byte < 32 { throw invalid() }
            }
        }

        private func spaces() throws {
            while let byte = try peek(), [9, 13, 32].contains(byte) { advance() }
        }

        private func expect(_ byte: UInt8) throws {
            guard try peek() == byte else { throw invalid() }
            advance()
        }

        private func advance() { index += 1; position += 1 }

        private func peek() throws -> UInt8? {
            if index == count {
                try flush()
                repeat { count = Darwin.read(descriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
                guard count >= 0 else { throw invalid() }
                index = 0; archived = 0
            }
            return index < count ? buffer[index] : nil
        }

        private func flush() throws {
            if let writer, archived < index { try writer.append(Data(buffer[archived..<index])) }
            archived = index
        }

        private func invalid() -> StorageMigrationError { .invalidApplicationStorage("chat transcript near byte \(position)") }
    }

    private static func durableDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func migrate(_ profile: Profile) async throws -> Profile {
        try recoverDurablePublications()
        try recoverPublicProfilePublications()
        guard let config = ProfileIO.readConfig(at: profile.url), config.id == profile.id, sourceVersion(for: config.version) != nil else {
            Log.app.error("StorageMigrator.reject unknown version=\(profile.version) id=\(profile.id)")
            throw StorageMigrationError.unsupportedProfileVersion(profile.name, profile.version)
        }
        var migrated = profile
        migrated.version = config.version
        if config.version == publicProfileVersion {
            guard profile.location == .local, config.contentDirectory == profile.name,
                  FileManager.default.fileExists(atPath: ProfileIO.stateDirectory(profile.id).appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("private Profile database")
            }
            return migrated
        }
        if config.version == filesystemProfileVersion {
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local filesystem Profile database")
            }
            return try await migratePublicProfile(migrated, config: config, destination: ProfileIO.publicProfiles.appendingPathComponent(profile.name))
        }
        if config.version == fileBindingVersion {
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local Profile filesystem database")
            }
            try await prepareFiles(at: profile.url, profileID: profile.id)
            var manifest = config
            manifest.version = filesystemProfileVersion
            try ProfileIO.writeConfig(manifest, to: profile.url)
            try syncDurableDirectory(profile.url)
            migrated.version = filesystemProfileVersion
            return try await migrate(migrated)
        }
        if config.version == profileFilesystemVersion {
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local Profile filesystem database")
            }
            try await prepareFiles(at: profile.url, profileID: profile.id)
            var manifest = config
            manifest.version = fileBindingVersion
            try ProfileIO.writeConfig(manifest, to: profile.url)
            try syncDurableDirectory(profile.url)
            migrated.version = fileBindingVersion
            return try await migrate(migrated)
        }
        if config.version == durableProfileVersion {
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local Pi Profile database")
            }
            try await prepareFiles(at: profile.url, profileID: profile.id)
            var manifest = config
            manifest.version = profileFilesystemVersion
            try ProfileIO.writeConfig(manifest, to: profile.url)
            try syncDurableDirectory(profile.url)
            migrated.version = profileFilesystemVersion
            return try await migrate(migrated)
        }
        guard profile.location == .local else { throw StorageMigrationError.invalidApplicationStorage("Pi Profiles require an offline local import; live cloud/external database synchronization is unsupported") }
        let working = profile.url.deletingLastPathComponent().appendingPathComponent(".pi-source-work-" + UUID().uuidString)
        let inventory = try await Task.detached(priority: .userInitiated) {
            try StorageMigrationSupport.copyMigrationSource(from: profile.url, to: working)
        }.value
        var draft = migrated
        draft.url = working
        try await migrateProfile(draft)
        draft.version = nativeProfileVersion
        let destination = profile.url.deletingLastPathComponent().appendingPathComponent(".pi-stage-" + UUID().uuidString)
        let staged = try await stageDurableProfile(draft, at: destination)
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
        try publishDurableJournal(journal)
        do { try FileManager.default.removeItem(at: working) }
        catch { Log.app.warning("StorageMigrator.pi workingCopy cleanup deferred error=\(error.localizedDescription)") }
        migrated.version = durableProfileVersion
        Log.app.info("StorageMigrator.pi activated id=\(profile.id) sourcePreserved=true")
        return try await migrate(migrated)
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

    static func migrateProfileSkillCatalog(at root: URL) throws {
        let manager = FileManager.default
        let skills = root.appendingPathComponent("skills")
        if manager.fileExists(atPath: skills.path) {
            for directory in try manager.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil) where SkillFiles.isLocalName(directory.lastPathComponent) {
                var skill = try SkillFiles.load(directory: directory)
                skill.instructions = StorageMigrationSupport.migratedSkillInstructions(skill.instructions)
                var destination = directory
                if ["import-memory", "manage-artifacts", "manage-services", "manage-skills"].contains(skill.name) {
                    skill.name = "user-" + skill.name
                    destination = skills.appendingPathComponent(skill.name)
                    if manager.fileExists(atPath: destination.path), try SkillFiles.load(directory: destination) != skill {
                        throw StorageMigrationError.collision(destination.lastPathComponent)
                    }
                }
                try SkillFiles.write(skill, directory: destination)
                if destination != directory { try manager.removeItem(at: directory) }
            }
        }
        let selections = root.appendingPathComponent("skill-selections.json")
        if manager.fileExists(atPath: selections.path) {
            guard try JSONDecoder().decode(SkillSelections.self, from: Data(contentsOf: selections)).version == 1 else { throw SkillError.invalidPackage }
        }
    }

    static func migrateReservedImportMemorySkill(at root: URL) throws {
        try migrateReservedSkill("import-memory", at: root)
    }

    static func migrateReservedOutcomeSkills(at root: URL) throws {
        for name in ["evolve", "visualize"] {
            try migrateReservedSkill(name, at: root)
        }
    }

    fileprivate static func migrateReservedSkill(_ name: String, at root: URL) throws {
        let manager = FileManager.default
        let source = root.appendingPathComponent("skills/\(name)", isDirectory: true)
        let destination = root.appendingPathComponent("skills/user-\(name)", isDirectory: true)
        let sourceExists = manager.fileExists(atPath: source.path)
        let destinationExists = manager.fileExists(atPath: destination.path)
        if sourceExists {
            var skill = try SkillFiles.load(directory: source)
            skill.name = "user-\(name)"
            if destinationExists {
                guard try SkillFiles.load(directory: destination) == skill else {
                    throw StorageMigrationError.collision("skills/user-\(name)")
                }
            } else {
                try SkillFiles.write(skill, directory: destination)
            }
        }
        let selectionsFile = root.appendingPathComponent("skill-selections.json")
        if manager.fileExists(atPath: selectionsFile.path) {
            var selections = try JSONDecoder().decode(SkillSelections.self, from: Data(contentsOf: selectionsFile))
            guard selections.version == 1 else { throw SkillError.invalidPackage }
            if selections.sources[name] == "user", sourceExists || destinationExists {
                guard selections.sources["user-\(name)"].map({ $0 == "user" }) ?? true else {
                    throw StorageMigrationError.collision("skill-selections.json:user-\(name)")
                }
                selections.sources["user-\(name)"] = "user"
                selections.sources.removeValue(forKey: name)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(selections).write(to: selectionsFile, options: .atomic)
            }
        }
        if sourceExists { try manager.removeItem(at: source) }
        Log.app.info("StorageMigrator.reservedSkill name=\(name) renamed=\(sourceExists)")
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

    nonisolated private static func materialize(at root: URL, timeout: TimeInterval = 60) async -> Bool {
        var evicted = requestDownloads(at: root)
        guard evicted > 0 else { return true }
        Log.app.info("StorageMigrator.materialize waiting evicted=\(evicted) root=\(root.lastPathComponent)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            evicted = requestDownloads(at: root)
            if evicted == 0 { return true }
        }
        Log.app.warning("StorageMigrator.materialize timeout evicted=\(evicted) root=\(root.lastPathComponent)")
        return false
    }

    nonisolated private static func requestDownloads(at root: URL) -> Int {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]) else { return 0 }
        var evicted = 0
        for case let url as URL in files {
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            guard status == .notDownloaded else { continue }
            try? fm.startDownloadingUbiquitousItem(at: url)
            evicted += 1
        }
        return evicted
    }

    nonisolated private static func stamp(_ version: String, at url: URL) throws {
        guard var config = ProfileIO.readConfig(at: url) else { throw StorageMigrationError.missingConfig }
        config.version = version
        try ProfileIO.writeConfig(config, to: url)
    }

    static func moveAttachmentsToFiles(at root: URL) throws {
        let fm = FileManager.default
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        guard fm.fileExists(atPath: attachments.path) else { return }
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        var references = 0
        for transcript in try transcriptURLs(at: root) {
            let data = try Data(contentsOf: transcript)
            var output = Data()
            var changed = false
            for line in data.split(separator: 0x0A) {
                let original = Data(line)
                guard var object = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
                      object["type"] as? String == "user",
                      var user = object["user"] as? [String: Any],
                      let values = user["attachments"] as? [Any] else {
                    output.append(original)
                    output.append(0x0A)
                    continue
                }
                var converted: [Any] = []
                var lineChanged = false
                for value in values {
                    guard let legacy = value as? [String: Any] else {
                        converted.append(value)
                        continue
                    }
                    guard let idString = legacy["id"] as? String,
                          let id = UUID(uuidString: idString),
                          let oldFileName = legacy["fileName"] as? String,
                          URL(fileURLWithPath: oldFileName).lastPathComponent == oldFileName,
                          let displayName = legacy["displayName"] as? String,
                          let mimeType = legacy["mimeType"] as? String,
                          let kindString = legacy["kind"] as? String,
                          let kind = FileItem.Kind(rawValue: kindString) else {
                        throw StorageMigrationError.invalidAttachment(transcript.path)
                    }
                    let ext = URL(fileURLWithPath: oldFileName).pathExtension
                    let metadata = FileMetadata(
                        id: id,
                        fileName: ext.isEmpty ? "content" : "content.\(ext)",
                        displayName: displayName,
                        mimeType: mimeType,
                        kind: kind
                    )
                    let source = attachments.appendingPathComponent(oldFileName, isDirectory: false)
                    try importLegacyFile(metadata, source: source, into: artifacts)
                    try finishLegacyImport(metadata, source: source, artifacts: artifacts)
                    converted.append(id.uuidString)
                    lineChanged = true
                    references += 1
                }
                user["attachments"] = converted
                object["user"] = user
                let encoded = try JSONSerialization.data(withJSONObject: object)
                output.append(encoded)
                output.append(0x0A)
                changed = changed || lineChanged
            }
            if changed { try output.write(to: transcript, options: .atomic) }
        }
        let leftovers = try fm.contentsOfDirectory(at: attachments, includingPropertiesForKeys: [.isRegularFileKey])
        var recovered = 0
        for source in leftovers {
            guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw StorageMigrationError.invalidAttachment(source.path)
            }
            let ext = source.pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            let kind: FileItem.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .pdf) ? .pdf : .text
            let id = UUID(uuidString: source.deletingPathExtension().lastPathComponent) ?? UUID()
            let metadata = FileMetadata(
                id: id,
                fileName: ext.isEmpty ? "content" : "content.\(ext)",
                displayName: source.lastPathComponent,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                kind: kind
            )
            try importLegacyFile(metadata, source: source, into: artifacts)
            try finishLegacyImport(metadata, source: source, artifacts: artifacts)
            recovered += 1
        }
        guard try fm.contentsOfDirectory(atPath: attachments.path).isEmpty else {
            throw StorageMigrationError.invalidAttachment(attachments.path)
        }
        try fm.removeItem(at: attachments)
        Log.app.info("StorageMigrator.moveAttachmentsToFiles root=\(root.lastPathComponent) references=\(references) recovered=\(recovered)")
    }

    static func renameLibraryToFiles(at root: URL) throws {
        let fm = FileManager.default
        let library = root.appendingPathComponent("library", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        guard fm.fileExists(atPath: library.path) else { return }
        if !fm.fileExists(atPath: artifacts.path) {
            try fm.moveItem(at: library, to: artifacts)
            Log.app.info("StorageMigrator.renameLibraryToFiles root=\(root.lastPathComponent) moved=directory")
            return
        }
        let items = try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        for item in items {
            let destination = artifacts.appendingPathComponent(item.lastPathComponent, isDirectory: false)
            if fm.fileExists(atPath: destination.path) {
                guard try equivalent(item, destination) else {
                    throw StorageMigrationError.collision(destination.path)
                }
                try fm.removeItem(at: item)
            } else {
                try fm.moveItem(at: item, to: destination)
            }
        }
        try fm.removeItem(at: library)
        Log.app.info("StorageMigrator.renameLibraryToFiles root=\(root.lastPathComponent) moved=\(items.count)")
    }

    static func moveConversationsIntoDirectories(at root: URL) throws {
        let fm = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: conversations.path) else { return }
        let entries = try fm.contentsOfDirectory(at: conversations, includingPropertiesForKeys: [.isRegularFileKey])
        let legacy = try entries.filter { item in
            guard ["json", "jsonl"].contains(item.pathExtension),
                  UUID(uuidString: item.deletingPathExtension().lastPathComponent) != nil else { return false }
            return try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        let grouped = Dictionary(grouping: legacy) {
            UUID(uuidString: $0.deletingPathExtension().lastPathComponent)!
        }
        var moved = 0
        for (id, files) in grouped {
            let directory = conversations.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for source in files {
                let name = source.pathExtension == "json" ? "chat.json" : "turns.jsonl"
                let destination = directory.appendingPathComponent(name, isDirectory: false)
                if fm.fileExists(atPath: destination.path) {
                    guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
                        throw StorageMigrationError.collision(destination.path)
                    }
                    try fm.removeItem(at: source)
                } else {
                    try fm.moveItem(at: source, to: destination)
                }
                moved += 1
            }
        }
        Log.app.info("StorageMigrator.moveConversationsIntoDirectories root=\(root.lastPathComponent) conversations=\(grouped.count) files=\(moved)")
    }

    static func repairStorage(at root: URL) throws {
        try moveAttachmentsToFiles(at: root)
        try renameLibraryToFiles(at: root)
        try flattenLegacyFiles(at: root)
        try migrateLegacySkills(at: root)
        try moveConversationsIntoDirectories(at: root)
    }

    private static func legacyTurn(from data: Data, decoder: JSONDecoder) throws -> Turn {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard root["type"] as? String == "agent",
              var agent = root["agent"] as? [String: Any] else {
            return try decoder.decode(Turn.self, from: data)
        }
        var steps = (agent["steps"] ?? agent["content"]) as? [[String: Any]] ?? []
        let generation = legacyGenerationID(agent: &agent, steps: steps)
        steps = steps.map { canonicalLegacyStep($0, generation: generation) }
        agent["steps"] = steps
        agent.removeValue(forKey: "content")
        agent.removeValue(forKey: "model")
        root["agent"] = agent
        return try decoder.decode(Turn.self, from: try JSONSerialization.data(withJSONObject: root))
    }

    private static func legacyGenerationID(
        agent: inout [String: Any],
        steps: [[String: Any]]
    ) -> String? {
        if let generations = agent["generations"] as? [[String: Any]],
           let id = generations.first?["id"] as? String {
            return id
        }
        guard let model = agent["model"] as? String,
              let at = agent["at"],
              let outcome = agent["outcome"] else { return nil }
        let seed = (steps.first?["id"] as? String) ?? "\(at).\(model)"
        let id = StableID.uuid("legacy-generation.\(seed)").uuidString
        agent["generations"] = [[
            "id": id,
            "at": at,
            "model": model,
            "outcome": outcome,
        ]]
        return id
    }

    private static func canonicalLegacyStep(
        _ value: [String: Any],
        generation: String?
    ) -> [String: Any] {
        var step = value
        if step["generation"] == nil {
            step["generation"] = generation ?? step["id"]
        }
        guard step["type"] as? String == "action",
              var action = step["action"] as? [String: Any],
              action["type"] as? String == "execute",
              var execution = action["execute"] as? [String: Any] else { return step }
        let effects = (execution["effects"] ?? execution["trace"]) as? [[String: Any]] ?? []
        execution["effects"] = effects.compactMap(canonicalLegacyEffect)
        execution.removeValue(forKey: "trace")
        action["execute"] = execution
        step["action"] = action
        return step
    }

    private static func canonicalLegacyEffect(_ value: [String: Any]) -> [String: Any]? {
        var effect = value
        switch effect["type"] as? String {
        case "step":
            effect["type"] = "invocation"
            effect["invocation"] = effect.removeValue(forKey: "step")
        case "widget":
            return nil
        case "media":
            if effect["media"] == nil { effect["media"] = effect.removeValue(forKey: "artifact") }
        default:
            break
        }
        return effect
    }

    static func migrateAgentContexts(at root: URL) throws {
        let fm = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: conversations.path) else { return }
        guard let config = ProfileIO.readConfig(at: root) else { throw StorageMigrationError.missingConfig }
        let scope = ProfileScope(profileID: config.id, root: root, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        let encoder = JSONEncoder()
        let directories = try fm.contentsOfDirectory(
            at: conversations,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.sorted { $0.path < $1.path }
        var upgraded = 0
        var refreshed = 0
        for directory in directories {
            let metadataURL = directory.appendingPathComponent("chat.json", isDirectory: false)
            guard fm.fileExists(atPath: metadataURL.path) else { continue }
            var metadata = try decoder.decode(ConversationMeta.self, from: Data(contentsOf: metadataURL))
            guard [ConversationFormat.currentSchemaVersion, legacyConversationSchemaVersion].contains(metadata.schemaVersion) else {
                Log.app.warning("StorageMigrator.agentContext skipped=\(directory.lastPathComponent) schema=\(metadata.schemaVersion)")
                continue
            }
            let transcriptURL = directory.appendingPathComponent("turns.jsonl", isDirectory: false)
            let lines = fm.fileExists(atPath: transcriptURL.path) ? try transcriptLines(transcriptURL) : []
            let legacy = metadata.schemaVersion == legacyConversationSchemaVersion
            let decoded = try lines.map {
                legacy
                    ? try legacyTurn(from: $0, decoder: decoder)
                    : try decoder.decode(Turn.self, from: $0)
            }
            let turns = ConversationFormat.normalize(decoded)
            if legacy || turns != decoded {
                try blob(turns, encoder: encoder).write(to: transcriptURL, options: .atomic)
            }
            if legacy {
                metadata.schemaVersion = ConversationFormat.currentSchemaVersion
                try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
                upgraded += 1
            }
            let contextURL = directory.appendingPathComponent("context.json", isDirectory: false)
            guard let lastAgent = turns.lastIndex(where: { turn in
                if case .agent = turn { return true }
                return false
            }) else {
                if fm.fileExists(atPath: contextURL.path) { try fm.removeItem(at: contextURL) }
                continue
            }
            let stored = try? decoder.decode(AgentContextCheckpoint.self, from: Data(contentsOf: contextURL))
            let messages: [Message]
            let tokensBefore: Int
            if !legacy, let stored, let boundary = stored.boundary(in: turns), boundary <= lastAgent {
                let tail = boundary == lastAgent
                    ? []
                    : ConversationProjection.makeWireMessages(from: Array(turns[(boundary + 1)...lastAgent]))
                messages = stored.messages + tail
                tokensBefore = stored.tokensBefore
            } else {
                messages = ConversationProjection.makeWireMessages(from: Array(turns[...lastAgent]))
                tokensBefore = 0
            }
            let context = AgentContextCheckpoint(
                messages: messages,
                tokensBefore: tokensBefore,
                turns: turns,
                through: lastAgent
            )
            try encoder.encode(context).write(to: contextURL, options: .atomic)
            refreshed += 1
        }
        Log.app.info("StorageMigrator.agentContexts root=\(root.lastPathComponent) conversations=\(directories.count) refreshed=\(refreshed) upgraded=\(upgraded)")
    }

    static func removeRedundantAgentContexts(at root: URL) throws {
        let fm = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: conversations.path) else { return }
        guard let config = ProfileIO.readConfig(at: root) else { throw StorageMigrationError.missingConfig }
        let scope = ProfileScope(profileID: config.id, root: root, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        let directories = try fm.contentsOfDirectory(
            at: conversations,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.sorted { $0.path < $1.path }
        var scanned = 0
        var removed = 0
        var retained = 0
        var unreadable = 0
        for directory in directories {
            let contextURL = directory.appendingPathComponent("context.json", isDirectory: false)
            guard fm.fileExists(atPath: contextURL.path) else { continue }
            let transcriptURL = directory.appendingPathComponent("turns.jsonl", isDirectory: false)
            scanned += 1
            guard fm.fileExists(atPath: transcriptURL.path) else {
                unreadable += 1
                Log.app.warning("StorageMigrator.redundantAgentContexts retained=missing-transcript chat=\(directory.lastPathComponent)")
                continue
            }
            let turns: [Turn]
            do {
                let lines = try transcriptLines(transcriptURL)
                turns = try lines.map { try decoder.decode(Turn.self, from: $0) }
            } catch {
                unreadable += 1
                Log.app.warning("StorageMigrator.redundantAgentContexts retained=unreadable chat=\(directory.lastPathComponent) error=\(error.localizedDescription)")
                continue
            }
            if turns.requiresContextCheckpoint {
                retained += 1
            } else {
                try fm.removeItem(at: contextURL)
                removed += 1
            }
        }
        Log.app.info("StorageMigrator.redundantAgentContexts root=\(root.lastPathComponent) scanned=\(scanned) removed=\(removed) retained=\(retained) unreadable=\(unreadable)")
    }

    static func migrateConversationProviderDefinitions(at root: URL) throws {
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard FileManager.default.fileExists(atPath: conversations.path) else { return }
        let directories = try FileManager.default.contentsOfDirectory(at: conversations, includingPropertiesForKeys: [.isDirectoryKey])
        var count = 0
        for directory in directories {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let file = directory.appendingPathComponent("chat.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
            guard var selection = object["model"]?.objectValue,
                  let id = selection["providerID"]?.stringValue,
                  let modelID = selection["modelID"]?.stringValue,
                  let region = selection["region"]?.stringValue.flatMap(LLMRegion.init(rawValue:)) else { continue }
            selection["providerID"] = .string(StorageMigrationSupport.providerIdentity(id, region: region, modelID: modelID))
            selection.removeValue(forKey: "region")
            object["model"] = .object(selection)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(object)
            data.append(0x0A)
            try data.write(to: file, options: .atomic)
            count += 1
        }
        Log.app.info("StorageMigrator.conversationProviders migrated=\(count)")
    }

    static func retainedServiceDomains(_ domains: [String]) -> [String] {
        domains.filter { $0 != "ios:files" }
    }

    static func removeBrowserServiceAttachments(at root: URL) throws {
        let manager = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard manager.fileExists(atPath: conversations.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: conversations,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var conversationsChanged = 0
        var attachmentsRemoved = 0
        for directory in directories {
            let file = directory.appendingPathComponent("chat.json", isDirectory: false)
            guard manager.fileExists(atPath: file.path) else { continue }
            var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
            guard let domains = object["attachedServiceDomains"]?.arrayValue else { continue }
            let retained = domains.filter { $0.stringValue != BrowserFunctionCatalog.internalDomain }
            guard retained.count != domains.count else { continue }
            object["attachedServiceDomains"] = .array(retained)
            var data = try encoder.encode(object)
            data.append(0x0A)
            try data.write(to: file, options: .atomic)
            conversationsChanged += 1
            attachmentsRemoved += domains.count - retained.count
        }
        Log.app.info("StorageMigrator.browserAttachments chats=\(conversationsChanged) removed=\(attachmentsRemoved)")
    }

    static func migrateConversationModelSelections(at root: URL) throws {
        let manager = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard manager.fileExists(atPath: conversations.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: conversations,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        let fallbackRegion = modelMigrationFallbackRegion()
        let legacyKeys = ["clientID", "modelID", "region", "reasoningEffort"]
        var migrated = 0
        var incomplete = 0
        for directory in directories {
            let metadataURL = directory.appendingPathComponent("chat.json", isDirectory: false)
            guard manager.fileExists(atPath: metadataURL.path) else { continue }
            let data = try Data(contentsOf: metadataURL)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let hasLegacyValue = legacyKeys.contains { object[$0] != nil }
            guard hasLegacyValue else { continue }
            if object["model"] == nil,
               let providerID = object["clientID"] as? String,
               let modelID = object["modelID"] as? String {
                let region = (object["region"] as? String).flatMap(LLMRegion.init(rawValue:)) ?? fallbackRegion
                var selection: [String: Any] = [
                    "region": region.rawValue,
                    "providerID": providerID,
                    "modelID": modelID,
                ]
                if let reasoningEffort = object["reasoningEffort"] as? String {
                    selection["reasoningEffort"] = reasoningEffort
                }
                object["model"] = selection
                migrated += 1
            } else if object["model"] == nil {
                incomplete += 1
            }
            legacyKeys.forEach { object.removeValue(forKey: $0) }
            var encoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            encoded.append(0x0A)
            try encoded.write(to: metadataURL, options: .atomic)
        }
        Log.app.info("StorageMigrator.conversationModelSelections root=\(root.lastPathComponent) migrated=\(migrated) incomplete=\(incomplete)")
    }

    private static func modelMigrationFallbackRegion(defaults: UserDefaults = .standard) -> LLMRegion {
        if let data = defaults.data(forKey: ProviderRegistry.defaultModelKey),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let region = (object["region"] as? String).flatMap(LLMRegion.init(rawValue:)) {
            return region
        }
        if let region = defaults.string(forKey: "app.region").flatMap(LLMRegion.init(rawValue:)) {
            return region
        }
        return Locale.current.region?.identifier == "CN" ? .china : .global
    }

    static func migrateLegacySkills(at root: URL) throws {
        let legacy = root.appendingPathComponent("COMMANDS.md")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let text = try String(contentsOf: legacy, encoding: .utf8)
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        var existing = Set(try manager.contentsOfDirectory(atPath: skillsRoot.path))
        var claimed: Set<String> = []
        var migrated = 0
        for legacySkill in parseLegacySkills(text) {
            let base = SkillFiles.slug(legacySkill.name)
            guard !base.isEmpty else { continue }
            var suffix = 1
            while true {
                let name = suffix == 1 ? base : "\(base)-\(suffix)"
                suffix += 1
                guard !claimed.contains(name) else { continue }
                let description = legacySkill.instructions
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init) ?? name
                let skill = Skill(
                    name: name,
                    description: description,
                    instructions: legacySkill.instructions,
                    services: legacySkill.services
                )
                let directory = skillsRoot.appendingPathComponent(name, isDirectory: true)
                let file = directory.appendingPathComponent(SkillFiles.fileName)
                if existing.contains(name) {
                    guard let current = try? String(contentsOf: file, encoding: .utf8),
                          SkillFiles.parse(current, directoryName: name) == skill else { continue }
                } else {
                    let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                    defer { FileStaging.cleanup(staging, operation: "legacy-skill-migration") }
                    try SkillFiles.serialize(skill).write(
                        to: staging.appendingPathComponent(SkillFiles.fileName),
                        atomically: true,
                        encoding: .utf8
                    )
                    try manager.moveItem(at: staging, to: directory)
                    existing.insert(name)
                }
                claimed.insert(name)
                migrated += 1
                break
            }
        }
        try manager.removeItem(at: legacy)
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.commandsToSkills root=\(root.lastPathComponent) count=\(migrated)")
    }

    static func namespaceUserSkills(at root: URL) throws {
        let namespace = "profile"
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: skillsRoot.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var migrated = 0
        for source in directories {
            guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  !source.lastPathComponent.hasPrefix("."),
                  !source.lastPathComponent.hasPrefix("\(namespace):"),
                  let localName = legacySkillLocalName(source.lastPathComponent, namespace: namespace),
                  let text = try? String(
                    contentsOf: source.appendingPathComponent(SkillFiles.fileName),
                    encoding: .utf8
                  ),
                  let skill = SkillFiles.parse(text, directoryName: source.lastPathComponent) else { continue }
            let destinationName = "\(namespace):\(localName)"
            let migratedSkill = Skill(
                name: destinationName,
                description: skill.description,
                instructions: skill.instructions,
                services: skill.services
            )
            let destination = skillsRoot.appendingPathComponent(destinationName, isDirectory: true)
            let destinationFile = destination.appendingPathComponent(SkillFiles.fileName)
            if manager.fileExists(atPath: destination.path) {
                guard let existing = try? String(contentsOf: destinationFile, encoding: .utf8),
                      SkillFiles.parse(existing, directoryName: destinationName) == migratedSkill else {
                    throw StorageMigrationError.collision(destination.path)
                }
            } else {
                let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                defer { FileStaging.cleanup(staging, operation: "skill-namespace-migration") }
                try SkillFiles.serialize(migratedSkill).write(
                    to: staging.appendingPathComponent(SkillFiles.fileName),
                    atomically: true,
                    encoding: .utf8
                )
                try manager.moveItem(at: staging, to: destination)
            }
            try manager.removeItem(at: source)
            migrated += 1
        }
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.namespaceUserSkills root=\(root.lastPathComponent) count=\(migrated)")
    }

    private static func legacySkillLocalName(_ name: String, namespace: String) -> String? {
        if SkillFiles.isLocalName(name) { return name }
        let parts = name
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2,
              !["system", "service", namespace].contains(parts[0]),
              SkillFiles.isLocalName(parts[0]),
              SkillFiles.isLocalName(parts[1]) else { return nil }
        return "\(parts[0])-\(parts[1])"
    }

    private static func parseLegacySkills(_ text: String) -> [Skill] {
        var skills: [Skill] = []
        var name: String?
        var services: [String] = []
        var body: [Substring] = []
        func flush() {
            guard let name, !name.isEmpty else { return }
            let instructions = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            skills.append(Skill(
                name: name,
                description: instructions,
                instructions: instructions,
                services: services
            ))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                name = String(line.dropFirst(3))
                services = []
                body = []
            } else if name != nil {
                if body.isEmpty, services.isEmpty, line.hasPrefix("services:") {
                    services = line.dropFirst("services:".count)
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else {
                    body.append(line)
                }
            }
        }
        flush()
        return skills
    }

    static func removeUserSkillNamespace(at root: URL) throws {
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: skillsRoot.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var migrated = 0
        for source in directories {
            let sourceName = source.lastPathComponent
            let prefix = "profile:"
            guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  sourceName.hasPrefix(prefix),
                  SkillFiles.isUserName(String(sourceName.dropFirst(prefix.count))),
                  let text = try? String(
                    contentsOf: source.appendingPathComponent(SkillFiles.fileName),
                    encoding: .utf8
                  ),
                  let skill = SkillFiles.parse(text, directoryName: sourceName) else { continue }
            let destinationName = String(sourceName.dropFirst(prefix.count))
            let migratedSkill = Skill(
                name: destinationName,
                description: skill.description,
                instructions: skill.instructions,
                services: skill.services
            )
            let destination = skillsRoot.appendingPathComponent(destinationName, isDirectory: true)
            let destinationFile = destination.appendingPathComponent(SkillFiles.fileName)
            if manager.fileExists(atPath: destination.path) {
                guard let existing = try? String(contentsOf: destinationFile, encoding: .utf8),
                      SkillFiles.parse(existing, directoryName: destinationName) == migratedSkill else {
                    throw StorageMigrationError.collision(destination.path)
                }
            } else {
                let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                defer { FileStaging.cleanup(staging, operation: "plain-skill-name-migration") }
                try SkillFiles.serialize(migratedSkill).write(
                    to: staging.appendingPathComponent(SkillFiles.fileName),
                    atomically: true,
                    encoding: .utf8
                )
                try manager.moveItem(at: staging, to: destination)
            }
            try manager.removeItem(at: source)
            migrated += 1
        }
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.removeUserSkillNamespace root=\(root.lastPathComponent) count=\(migrated)")
    }

    private static func finishLegacyImport(_ metadata: FileMetadata, source: URL, artifacts: URL) throws {
        let destination = artifacts
            .appendingPathComponent(metadata.id.uuidString, isDirectory: true)
            .appendingPathComponent(metadata.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw StorageMigrationError.missingFile(destination.path)
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
            throw StorageMigrationError.collision(destination.path)
        }
        try FileManager.default.removeItem(at: source)
    }

    private static func importLegacyFile(
        _ metadata: FileMetadata,
        source: URL,
        into directory: URL
    ) throws {
        let folder = directory.appendingPathComponent(metadata.id.uuidString, isDirectory: true)
        let metadataURL = folder.appendingPathComponent(FileStore.metadataName, isDirectory: false)
        if FileManager.default.fileExists(atPath: metadataURL.path) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(metadata.fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: source.path),
           !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }

    private static func flattenLegacyFiles(at root: URL) throws {
        let fm = FileManager.default
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        guard fm.fileExists(atPath: artifacts.path) else { return }
        let entries = try fm.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: [.isDirectoryKey])
        let folders = try entries.filter { entry in
            guard UUID(uuidString: entry.lastPathComponent) != nil else { return false }
            return try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        var replacements: [String: String] = [:]
        for folder in folders {
            let metadataURL = folder.appendingPathComponent(FileStore.metadataName, isDirectory: false)
            let metadata: FileMetadata
            do {
                metadata = try JSONDecoder().decode(FileMetadata.self, from: Data(contentsOf: metadataURL))
            } catch {
                throw StorageMigrationError.invalidFile(folder.path)
            }
            guard metadata.id.uuidString.caseInsensitiveCompare(folder.lastPathComponent) == .orderedSame,
                  URL(fileURLWithPath: metadata.fileName).lastPathComponent == metadata.fileName else {
                throw StorageMigrationError.invalidFile(folder.path)
            }
            let source = folder.appendingPathComponent(metadata.fileName, isDirectory: false)
            guard fm.fileExists(atPath: source.path) else {
                throw StorageMigrationError.missingFile(source.path)
            }
            let data = try Data(contentsOf: source)
            let fileName = reusableFilename(
                suggested: displayName(metadata.displayName, contentName: metadata.fileName),
                id: metadata.id,
                data: data,
                directory: artifacts
            )
            let destination = artifacts.appendingPathComponent(fileName, isDirectory: false)
            if !fm.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
            replacements[metadata.id.uuidString.lowercased()] = fileName
        }
        for transcript in try transcriptURLs(at: root) {
            try rewriteFileReferences(in: transcript, replacements: replacements)
        }
        for folder in folders { try fm.removeItem(at: folder) }
        if !folders.isEmpty {
            Log.app.info("StorageMigrator.flattenLegacyFiles root=\(root.lastPathComponent) artifacts=\(folders.count)")
        }
    }

    private static func reusableFilename(suggested: String, id: UUID, data: Data, directory: URL) -> String {
        let cleaned = FileStore.sanitizedFilename(suggested)
        let url = URL(fileURLWithPath: cleaned)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let tag = String(id.uuidString.prefix(8)).lowercased()
        var candidates = [cleaned, ext.isEmpty ? "\(stem) \(tag)" : "\(stem) \(tag).\(ext)"]
        var suffix = 2
        while true {
            let candidate = candidates.removeFirst()
            let destination = directory.appendingPathComponent(candidate, isDirectory: false)
            if !FileManager.default.fileExists(atPath: destination.path) { return candidate }
            if let existing = try? Data(contentsOf: destination), existing == data { return candidate }
            candidates.append(ext.isEmpty ? "\(stem) \(tag)-\(suffix)" : "\(stem) \(tag)-\(suffix).\(ext)")
            suffix += 1
        }
    }

    private static func displayName(_ displayName: String, contentName: String) -> String {
        let cleaned = FileStore.sanitizedFilename(displayName)
        guard URL(fileURLWithPath: cleaned).pathExtension.isEmpty else { return cleaned }
        let ext = URL(fileURLWithPath: contentName).pathExtension
        return ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
    }

    private static func rewriteFileReferences(in transcript: URL, replacements: [String: String]) throws {
        guard !replacements.isEmpty else { return }
        let data = try Data(contentsOf: transcript)
        var output = Data()
        var changed = false
        for line in data.split(separator: 0x0A) {
            let original = Data(line)
            guard let object = try? JSONSerialization.jsonObject(with: original) else {
                output.append(original)
                output.append(0x0A)
                continue
            }
            let replacement = replaceFileReferences(object, replacements: replacements, enabled: false)
            if replacement.changed {
                output.append(try JSONSerialization.data(withJSONObject: replacement.value))
                changed = true
            } else {
                output.append(original)
            }
            output.append(0x0A)
        }
        if changed { try output.write(to: transcript, options: .atomic) }
    }

    private static func replaceFileReferences(_ value: Any, replacements: [String: String], enabled: Bool) -> (value: Any, changed: Bool) {
        if let string = value as? String, enabled, let replacement = replacements[string.lowercased()] {
            return (replacement, true)
        }
        if let values = value as? [Any] {
            var changed = false
            let output = values.map {
                let replacement = replaceFileReferences($0, replacements: replacements, enabled: enabled)
                changed = changed || replacement.changed
                return replacement.value
            }
            return (output, changed)
        }
        if let fields = value as? [String: Any] {
            var changed = false
            var output: [String: Any] = [:]
            for (key, child) in fields {
                let replaceStrings = enabled || ["attachments", "artifact", "media"].contains(key)
                let replacement = replaceFileReferences(child, replacements: replacements, enabled: replaceStrings)
                output[key] = replacement.value
                changed = changed || replacement.changed
            }
            return (output, changed)
        }
        return (value, false)
    }

    private static func transcriptURLs(at root: URL) throws -> [URL] {
        let fm = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: conversations.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: conversations, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
        var transcripts: [URL] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isRegularFile == true, entry.pathExtension == "jsonl" {
                transcripts.append(entry)
            } else if values.isDirectory == true {
                let transcript = entry.appendingPathComponent("turns.jsonl", isDirectory: false)
                if fm.fileExists(atPath: transcript.path) { transcripts.append(transcript) }
            }
        }
        return transcripts.sorted { $0.path < $1.path }
    }

    private static func transcriptLines(_ url: URL) throws -> [Data] {
        try [UInt8](Data(contentsOf: url)).split(separator: 0x0A).map { Data($0) }
    }

    private static func blob(_ turns: [Turn], encoder: JSONEncoder) throws -> Data {
        try turns.reduce(into: Data()) { output, turn in
            output.append(try encoder.encode(turn))
            output.append(0x0A)
        }
    }

    private static func equivalent(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        let left = try lhs.resourceValues(forKeys: keys)
        let right = try rhs.resourceValues(forKeys: keys)
        guard left.isDirectory == right.isDirectory, left.isRegularFile == right.isRegularFile else { return false }
        if left.isRegularFile == true { return try Data(contentsOf: lhs) == Data(contentsOf: rhs) }
        guard left.isDirectory == true else { return false }
        let fm = FileManager.default
        let leftNames = try fm.contentsOfDirectory(atPath: lhs.path).sorted()
        let rightNames = try fm.contentsOfDirectory(atPath: rhs.path).sorted()
        guard leftNames == rightNames else { return false }
        for name in leftNames {
            guard try equivalent(lhs.appendingPathComponent(name), rhs.appendingPathComponent(name)) else { return false }
        }
        return true
    }
}

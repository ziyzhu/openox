import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

extension ProfileMigrator {
    static func createFreshProfile(name: String, base: URL, unique: Bool = false) async throws -> Profile {
        let manager = FileManager.default
        if base.standardizedFileURL == ProfileIO.publicProfiles.standardizedFileURL {
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
        }
        let stem = ProfileRepository.cleanName(name)
        var candidate = stem
        var suffix = 2
        while manager.fileExists(atPath: base.appendingPathComponent(candidate).path) {
            guard unique else { throw ProfileError.nameExists(name) }
            candidate = "\(stem) \(suffix)"; suffix += 1
        }
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
            let state = ProfileIO.portableStateDirectory(stage)
            try manager.createDirectory(at: state, withIntermediateDirectories: false)
            for name in ["state.sqlite", "state.sqlite-wal", "state.sqlite-shm"] {
                let source = stage.appendingPathComponent(name)
                if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: state.appendingPathComponent(name)) }
            }
            let legacyStaging = stage.appendingPathComponent(".files")
            if manager.fileExists(atPath: legacyStaging.path) { try manager.removeItem(at: legacyStaging) }
            manifest.version = ProfileSchema.current
            try ProfileIO.writeConfig(manifest, to: stage)
            try await preparePublicFiles(content: stage, state: state, profileID: manifest.id)
            try syncImportedTree(stage)
            let draftProfile = Profile(id: manifest.id, name: candidate, location: .local, url: stage, createdAt: manifest.createdAt, version: manifest.version)
            let (created, _) = try copyProfile(draftProfile, to: base)
            Log.app.info("StorageMigrator.fresh published id=\(created.id) location=\(created.location.rawValue)")
            return created
        } catch {
            await runtime.dispose()
            Log.app.error("StorageMigrator.fresh failed stage=\(stage.lastPathComponent) error=\(error.localizedDescription)")
            throw error
        }
    }

    static func copyProfile(_ profile: Profile, to parent: URL) throws -> (Profile, [String: String]) {
        let manager = FileManager.default
        let destination = parent.appendingPathComponent(profile.name, isDirectory: true)
        let sourceParts = profile.url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard !parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents.starts(with: sourceParts) else {
            throw RuntimeError.bridge("Choose a location outside this Profile folder.")
        }
        guard !manager.fileExists(atPath: destination.path) else { throw ProfileError.nameExists(profile.name) }
        let stage = parent.appendingPathComponent(".ox-move-" + UUID().uuidString, isDirectory: true)
        var result: Result<[String: String], Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: profile.url, options: [], writingItemAt: parent, options: [], error: &coordinationError) { source, target in
            result = Result {
                let working = target.appendingPathComponent(stage.lastPathComponent, isDirectory: true)
                defer {
                    if manager.fileExists(atPath: working.path) {
                        do { try manager.removeItem(at: working) }
                        catch { Log.app.warning("ProfileTransfer.cleanup failed stage=\(working.lastPathComponent)") }
                    }
                }
                let inventory = try transferInventory(at: source)
                try manager.copyItem(at: source, to: working)
                guard try transferInventory(at: source) == inventory, try transferInventory(at: working) == inventory else {
                    throw RuntimeError.bridge("The Profile changed while copying. The original folder has been kept.")
                }
                try syncImportedTree(working)
                try manager.moveItem(at: working, to: target.appendingPathComponent(profile.name, isDirectory: true))
                try syncDurableDirectory(target)
                return inventory
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw RuntimeError.bridge("The Profile folder could not be copied.") }
        let inventory = try result.get()
        var copied = profile
        copied.url = destination
        copied.location = parent.standardizedFileURL == ProfileIO.publicProfiles.standardizedFileURL ? .local : .external
        Log.app.info("ProfileRepository.copy id=\(profile.id) files=\(inventory.count)")
        return (copied, inventory)
    }

    private static func transferInventory(at root: URL) throws -> [String: String] {
        var inventory = try StorageMigrationSupport.migrationSourceInventory(at: root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw RuntimeError.bridge("The Profile folder could not be read.")
        }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                inventory[url.pathComponents.suffix(enumerator.level).joined(separator: "/") + "/"] = "directory"
            }
        }
        return inventory
    }

    static func removeMovedSource(_ profile: Profile, inventory: [String: String]) throws {
        var result: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: profile.url, options: .forDeleting, error: &coordinationError) { source in
            result = Result {
                guard try transferInventory(at: source) == inventory else {
                    throw RuntimeError.bridge("The original folder changed after copying. Both copies have been kept.")
                }
                try FileManager.default.removeItem(at: source)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw RuntimeError.bridge("The original folder could not be removed. Both copies have been kept.") }
        try result.get()
        Log.app.info("ProfileRepository.move removedOriginal id=\(profile.id)")
    }

    static func prepareTemporaryFiles(at root: URL, identity: UUID) async throws {
        let runtime = DurableRuntime(databaseURL: root.appendingPathComponent("state.sqlite"), fileRoot: root) { method, _, _ in
            throw RuntimeError.bridge("Temporary files preparation forbids native capabilities: \(method)")
        }
        do {
            _ = try await runtime.command(.object(["action": .string("open"), "profileID": .string(identity.uuidString),
                "physicalFiles": .bool(true), "prepareFiles": .bool(true), "artifactFiles": .bool(true)]))
            let files = try await runtime.command(.object(["action": .string("filesPrepare")]))
            let publicFiles = try await runtime.command(.object(["action": .string("publicFilesPrepare"), "splitStorage": .bool(false)]))
            _ = try await runtime.command(.object(["action": .string("close")]))
            await runtime.dispose()
            try syncDurableDirectory(root)
            Log.app.info("ProfileMigrator.temporaryFiles prepared profile=\(identity) files=\(files.jsonString()) publicFiles=\(publicFiles.jsonString())")
        } catch {
            await runtime.dispose()
            throw error
        }
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
        config.version = publicProfileVersion
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
        return try await migrate(profile)
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

    static func syncImportedTree(_ root: URL) throws {
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

    static func prepareFiles(at root: URL, profileID: UUID) async throws {
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

    static func preparePublicFiles(content: URL, state: URL, profileID: UUID) async throws {
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

    static func migratePublicProfile(_ profile: Profile, config: ProfileConfig, destination: URL) async throws -> Profile {
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

    static func recoverPublicProfilePublications() throws {
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
}

import Foundation
import SwiftGitX
import UniformTypeIdentifiers

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
    ]
    static var current: String { versions.last! }

    static let steps: [@Sendable (URL) throws -> Void] = [
        { _ in },
        { _ in },
        { try ProfileMigrator.moveAttachmentsToArtifacts(at: $0) },
        { try ProfileMigrator.migrateLegacySkills(at: $0) },
        { _ in },
        { try ProfileMigrator.renameLibraryToArtifacts(at: $0) },
        { try ProfileMigrator.moveChatsIntoDirectories(at: $0) },
        { try ProfileMigrator.repairStorage(at: $0) },
        { try ProfileMigrator.migrateAgentContexts(at: $0) },
        { try ProfileMigrator.namespaceUserSkills(at: $0) },
        { try ProfileMigrator.removeUserSkillNamespace(at: $0) },
        { _ in },
    ]
}

nonisolated enum ProfileMigrationError: LocalizedError {
    case collision(String)
    case invalidAttachment(String)
    case invalidArtifact(String)
    case invalidLocalServiceRepositorySeed
    case invalidRepairedLocalServiceRepository
    case missingArtifact(String)
    case missingConfig
    case localServiceRepositoryRollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .collision(let path): "Migration destination conflicts with existing data: \(path)"
        case .invalidAttachment(let path): "Legacy attachment metadata is invalid: \(path)"
        case .invalidArtifact(let path): "Legacy artifact metadata is invalid: \(path)"
        case .invalidLocalServiceRepositorySeed: "The Local service repository repair seed is invalid."
        case .invalidRepairedLocalServiceRepository: "The repaired Local service repository is invalid."
        case .missingArtifact(let path): "Legacy artifact content is missing: \(path)"
        case .missingConfig: "The Profile configuration could not be read."
        case .localServiceRepositoryRollbackFailed(let detail): "The Local service repository repair and rollback failed: \(detail)"
        }
    }
}

nonisolated enum ProfileMigrator {
    private enum LegacyLocalServiceRepositoryState {
        case main(String)
        case empty
        case unsupported([String])
    }

    private struct LegacyProfileRecord: Decodable {
        let id: UUID
        let location: Profile.Location
        let bookmark: Data?
    }

    static func migrateExternalProfiles(
        in support: URL,
        destination: URL? = nil
    ) -> (URL, [ProfileStore.ExternalRecord]) {
        let destination = destination ?? AppStoragePaths.externalProfiles(in: support)
        let legacyDirectory = support.appendingPathComponent("profiles", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        if let data = try? Data(contentsOf: destination),
           let stored = try? JSONDecoder().decode([ProfileStore.ExternalRecord].self, from: data) {
            do {
                try removeLegacyFile(legacyURL, directory: legacyDirectory)
            } catch {
                Log.app.error("ProfileMigrator.externalProfiles cleanup failed: \(error.localizedDescription)")
            }
            return (destination, stored)
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([LegacyProfileRecord].self, from: data) else {
            return (destination, [])
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
            Log.app.info("ProfileMigrator.externalProfiles migrated=\(records.count) discardedManaged=\(legacy.count - records.count)")
        } catch {
            Log.app.error("ProfileMigrator.externalProfiles failed: \(error.localizedDescription)")
        }
        return (destination, records)
    }

    static func migrateDeviceFolderGrants(in support: URL, destination: URL? = nil) -> URL {
        let destination = destination ?? AppStoragePaths.deviceFolderGrants(in: support)
        let legacyDirectory = support.appendingPathComponent("device-folders", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("grants.json", isDirectory: false)
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: destination),
           (try? decoder.decode([DeviceFolderStore.Grant].self, from: data)) != nil {
            do {
                try removeLegacyFile(legacyURL, directory: legacyDirectory)
            } catch {
                Log.app.error("ProfileMigrator.deviceFolderGrants cleanup failed: \(error.localizedDescription)")
            }
            return destination
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let grants = try? decoder.decode([DeviceFolderStore.Grant].self, from: data) else {
            return destination
        }
        do {
            try data.write(to: destination, options: .atomic)
            try? AppStoragePaths.excludeFromBackup(destination)
            try removeLegacyFile(legacyURL, directory: legacyDirectory)
            Log.app.info("ProfileMigrator.deviceFolderGrants migrated=\(grants.count)")
        } catch {
            Log.app.error("ProfileMigrator.deviceFolderGrants failed: \(error.localizedDescription)")
        }
        return destination
    }

    static func migrateRemoteMCPServers(
        defaults: UserDefaults,
        currentKey: String
    ) -> [ServiceManager.PersistedRemoteMCP] {
        let legacyKey = "remoteMCPEndpoints"
        if let data = defaults.data(forKey: currentKey),
           let stored = try? JSONDecoder().decode([ServiceManager.PersistedRemoteMCP].self, from: data) {
            defaults.removeObject(forKey: legacyKey)
            return stored
        }
        let migrated = (defaults.stringArray(forKey: legacyKey) ?? []).map {
            ServiceManager.PersistedRemoteMCP(endpoint: $0, transport: nil)
        }
        guard !migrated.isEmpty else { return [] }
        do {
            defaults.set(try JSONEncoder().encode(migrated), forKey: currentKey)
            defaults.removeObject(forKey: legacyKey)
            Log.app.info("ProfileMigrator.remoteMCPServers migrated=\(migrated.count)")
        } catch {
            Log.app.error("ProfileMigrator.remoteMCPServers failed: \(error.localizedDescription)")
        }
        return migrated
    }

    static func migrateCustomLLMProviders(
        defaults: UserDefaults,
        key: String
    ) -> [CustomLLMProvider] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            let providers = try JSONDecoder().decode([CustomLLMProvider].self, from: data)
            let legacyModelsStored = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            if legacyModelsStored?.contains(where: { $0["models"] != nil }) == true {
                defaults.set(try JSONEncoder().encode(providers), forKey: key)
                Log.app.info("ProfileMigrator.customLLMProviders removed legacy models providers=\(providers.count)")
            }
            return providers
        } catch {
            Log.app.error("ProfileMigrator.customLLMProviders failed error=\(error.localizedDescription)")
            return []
        }
    }

    static func migrateLegacyLocalServiceRepository(at root: URL, seed: URL?) throws {
        let manager = FileManager.default
        let metadata = root.appendingPathComponent(".git", isDirectory: true)
        guard manager.fileExists(atPath: metadata.path) else { return }
        let headURL = metadata.appendingPathComponent("HEAD", isDirectory: false)
        guard let headData = try? Data(contentsOf: headURL),
              String(decoding: headData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "ref: refs/heads/master"
        else { return }

        switch try legacyLocalServiceRepositoryState(at: root) {
        case .main(let expectedCommit):
            do {
                try Data("ref: refs/heads/main\n".utf8).write(to: headURL, options: .atomic)
                guard try localServiceRepositoryCommit(at: root) == expectedCommit else {
                    throw ProfileMigrationError.invalidRepairedLocalServiceRepository
                }
            } catch {
                do {
                    try headData.write(to: headURL, options: .atomic)
                } catch let rollbackError {
                    throw ProfileMigrationError.localServiceRepositoryRollbackFailed(rollbackError.localizedDescription)
                }
                throw error
            }
            Log.service.info("ProfileMigrator.localServiceRepository repaired=head commit=\(expectedCommit.prefix(12))")
        case .empty:
            guard let seed, manager.fileExists(atPath: seed.path) else {
                throw ProfileMigrationError.invalidLocalServiceRepositorySeed
            }
            try replaceLegacyLocalServiceRepositoryMetadata(at: root, metadata: metadata, seed: seed)
            Log.service.info("ProfileMigrator.localServiceRepository repaired=seed preservedWorkingTree=true")
        case .unsupported(let references):
            Log.service.warning("ProfileMigrator.localServiceRepository skipped references=\(references.joined(separator: ","))")
        }
    }

    static func migrateLegacyLocalServiceManifests(at root: URL) throws {
        let repository = try SwiftGitX.Repository.open(at: root)
        guard !repository.isHEADDetached else { return }
        let status = try repository.status()
        let changedPaths = Set(status.flatMap {
            [
                $0.workingTree?.newFile.path,
                $0.workingTree?.oldFile.path,
                $0.index?.newFile.path,
                $0.index?.oldFile.path,
            ].compactMap { $0 }
        })
        let hasStagedChanges = status.contains {
            $0.status.contains(where: {
                [.indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange, .conflicted].contains($0)
            })
        }
        let manager = FileManager.default
        let webRoot = root.appendingPathComponent("web", isDirectory: true)
        guard manager.fileExists(atPath: webRoot.path) else { return }
        var cleanPaths: [String] = []
        var pendingCount = 0
        for directory in try manager.contentsOfDirectory(
            at: webRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let legacyURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            let currentURL = directory.appendingPathComponent("service.json", isDirectory: false)
            guard manager.fileExists(atPath: legacyURL.path),
                  !manager.fileExists(atPath: currentURL.path) else { continue }
            let rootPath = "web/\(directory.lastPathComponent)"
            let legacyPath = "\(rootPath)/manifest.json"
            let currentPath = "\(rootPath)/service.json"
            try manager.moveItem(at: legacyURL, to: currentURL)
            if changedPaths.contains(legacyPath) || changedPaths.contains(currentPath) {
                pendingCount += 1
            } else {
                cleanPaths.append(contentsOf: [legacyPath, currentPath])
            }
        }
        if !cleanPaths.isEmpty, !hasStagedChanges {
            try repository.add(paths: cleanPaths.sorted())
            let commit = try repository.commit(message: "Rename Local service manifests to service.json")
            Log.service.info("ProfileMigrator.localServiceManifests saved=\(cleanPaths.count / 2) commit=\(commit.id.abbreviated)")
        } else if hasStagedChanges {
            pendingCount += cleanPaths.count / 2
        }
        if pendingCount > 0 {
            Log.service.info("ProfileMigrator.localServiceManifests pending=\(pendingCount)")
        }
    }

    static func migrateLegacyLocalServiceActions(at root: URL) throws {
        let repository = try SwiftGitX.Repository.open(at: root)
        guard !repository.isHEADDetached else { return }
        let status = try repository.status()
        let dirtyPaths = Set(status.compactMap {
            $0.workingTree?.newFile.path ?? $0.index?.newFile.path ?? $0.index?.oldFile.path
        })
        let hasStagedChanges = status.contains {
            $0.status.contains(where: {
                [.indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange, .conflicted].contains($0)
            })
        }
        let webRoot = root.appendingPathComponent("web", isDirectory: true)
        guard FileManager.default.fileExists(atPath: webRoot.path) else { return }
        var cleanPaths: [String] = []
        var dirtyCount = 0
        for directory in try FileManager.default.contentsOfDirectory(
            at: webRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let actionsURL = directory.appendingPathComponent("actions.js", isDirectory: false)
            let currentManifestURL = directory.appendingPathComponent("service.json", isDirectory: false)
            let legacyManifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            let manifestURL = FileManager.default.fileExists(atPath: currentManifestURL.path) ? currentManifestURL : legacyManifestURL
            guard let source = try? String(contentsOf: actionsURL, encoding: .utf8),
                  source.range(of: #"window\s*\.\s*ox\s*\.\s*install\s*\("#, options: .regularExpression) == nil,
                  source.contains("callServiceAction"),
                  let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  let actions = manifest["actions"] as? [[String: Any]],
                  actions.count > 0
            else { continue }
            let identifiers = actions.compactMap { $0["id"] as? String }
            guard identifiers.count == actions.count else { continue }
            let migrated = try migratedServiceActions(source, identifiers: identifiers)
            try migrated.write(to: actionsURL, atomically: true, encoding: .utf8)
            let path = "web/\(directory.lastPathComponent)/actions.js"
            if dirtyPaths.contains(path) {
                dirtyCount += 1
            } else {
                cleanPaths.append(path)
            }
        }
        if !cleanPaths.isEmpty, !hasStagedChanges {
            try repository.add(paths: cleanPaths.sorted())
            let commit = try repository.commit(message: "Migrate Local service actions to ABI v1")
            Log.service.info("ProfileMigrator.localServiceActions saved=\(cleanPaths.count) commit=\(commit.id.abbreviated)")
        }
        if dirtyCount > 0 || (!cleanPaths.isEmpty && hasStagedChanges) {
            Log.service.info("ProfileMigrator.localServiceActions pending=\(dirtyCount + (hasStagedChanges ? cleanPaths.count : 0))")
        }
    }

    static func migrate(_ profile: Profile) async -> Bool {
        let sourceVersion = ["2026-07-12", "2026-07-12-ids"].contains(profile.version) ? "2026-07-11" : profile.version
        guard let from = ProfileSchema.versions.firstIndex(of: sourceVersion) else {
            Log.app.info("ProfileMigrator.skip unknown version=\(profile.version) id=\(profile.id)")
            return false
        }
        let target = ProfileSchema.versions.count - 1
        guard from < target else { return true }
        let url = profile.url
        let id = profile.id
        let was = profile.version
        return await Task.detached(priority: .userInitiated) {
            let complete = await materialize(at: url)
            guard complete else {
                Log.app.warning("ProfileMigrator.deferred id=\(id) version=\(was) awaiting downloads")
                return false
            }
            Log.app.info("ProfileMigrator.start id=\(id) from=\(was) to=\(ProfileSchema.current)")
            for step in from..<target {
                let version = ProfileSchema.versions[step + 1]
                do {
                    try ProfileSchema.steps[step](url)
                    try stamp(version, at: url)
                } catch {
                    Log.app.error("ProfileMigrator.failed id=\(id) step=\(version) error=\(error.localizedDescription)")
                    return false
                }
            }
            Log.app.info("ProfileMigrator.done id=\(id) version=\(ProfileSchema.current)")
            return true
        }.value
    }

    nonisolated private static func materialize(at root: URL, timeout: TimeInterval = 60) async -> Bool {
        var evicted = requestDownloads(at: root)
        guard evicted > 0 else { return true }
        Log.app.info("ProfileMigrator.materialize waiting evicted=\(evicted) root=\(root.lastPathComponent)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            evicted = requestDownloads(at: root)
            if evicted == 0 { return true }
        }
        Log.app.warning("ProfileMigrator.materialize timeout evicted=\(evicted) root=\(root.lastPathComponent)")
        return false
    }

    private static func migratedServiceActions(_ source: String, identifiers: [String]) throws -> String {
        let registrations = try identifiers.map { identifier in
            let data = try JSONEncoder().encode(identifier)
            let encoded = String(decoding: data, as: UTF8.self)
            return "  action(\(encoded), { async invoke(args) { return __oxLegacyCall(\(encoded), args); } });"
        }.joined(separator: "\n")
        return """
        {
          const __oxRuntime = window.ox;
          const __oxRuntimeCallServiceAction = __oxRuntime.callServiceAction;
          let __oxLegacyCall;
          try {
        \(source)
            if (typeof window.ox?.callServiceAction === "function") {
              __oxLegacyCall = window.ox.callServiceAction.bind(window.ox);
            }
          } finally {
            window.ox = __oxRuntime;
            __oxRuntime.callServiceAction = __oxRuntimeCallServiceAction;
          }
          if (typeof __oxLegacyCall !== "function") throw new Error("legacy service dispatcher is unavailable");
          window.ox.install(1, ({ action }) => {
        \(registrations)
          });
        }
        """
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
        guard var config = ProfileIO.readConfig(at: url) else { throw ProfileMigrationError.missingConfig }
        config.version = version
        try ProfileIO.writeConfig(config, to: url)
    }

    nonisolated private static func removeLegacyFile(_ url: URL, directory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
        if try manager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try manager.removeItem(at: directory)
        }
    }

    private static func legacyLocalServiceRepositoryState(at root: URL) throws -> LegacyLocalServiceRepositoryState {
        let repository = try SwiftGitX.Repository.open(at: root)
        if let main = repository.reference["refs/heads/main"], let commit = main.target as? Commit {
            return .main(commit.id.hex)
        }
        let references = try repository.reference.list().map(\.fullName).sorted()
        return references.isEmpty && repository.isEmpty ? .empty : .unsupported(references)
    }

    private static func replaceLegacyLocalServiceRepositoryMetadata(
        at root: URL,
        metadata: URL,
        seed: URL
    ) throws {
        let manager = FileManager.default
        let parent = metadata.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".git-repair-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent(".git-legacy-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.copyItem(at: seed, to: staging)
            try manager.moveItem(at: metadata, to: backup)
            do {
                try manager.moveItem(at: staging, to: metadata)
                _ = try localServiceRepositoryCommit(at: root)
            } catch {
                do {
                    if manager.fileExists(atPath: metadata.path) {
                        try manager.removeItem(at: metadata)
                    }
                    try manager.moveItem(at: backup, to: metadata)
                } catch let rollbackError {
                    throw ProfileMigrationError.localServiceRepositoryRollbackFailed(rollbackError.localizedDescription)
                }
                throw error
            }
            do {
                try manager.removeItem(at: backup)
            } catch {
                Log.service.warning("ProfileMigrator.localServiceRepository backup cleanup failed error=\(error.localizedDescription)")
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func localServiceRepositoryCommit(at root: URL) throws -> String {
        let repository = try SwiftGitX.Repository.open(at: root)
        guard let head = try repository.HEAD.target as? Commit,
              let main = repository.reference["refs/heads/main"],
              let tip = main.target as? Commit,
              head.id == tip.id else {
            throw ProfileMigrationError.invalidRepairedLocalServiceRepository
        }
        return head.id.hex
    }

    static func moveAttachmentsToArtifacts(at root: URL) throws {
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
                          let kind = Artifact.Kind(rawValue: kindString) else {
                        throw ProfileMigrationError.invalidAttachment(transcript.path)
                    }
                    let ext = URL(fileURLWithPath: oldFileName).pathExtension
                    let metadata = ArtifactMetadata(
                        id: id,
                        fileName: ext.isEmpty ? "content" : "content.\(ext)",
                        displayName: displayName,
                        mimeType: mimeType,
                        kind: kind
                    )
                    let source = attachments.appendingPathComponent(oldFileName, isDirectory: false)
                    try ArtifactStore.importLegacy(metadata, source: source, into: artifacts)
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
                throw ProfileMigrationError.invalidAttachment(source.path)
            }
            let ext = source.pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            let kind: Artifact.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .pdf) ? .pdf : .text
            let id = UUID(uuidString: source.deletingPathExtension().lastPathComponent) ?? UUID()
            let metadata = ArtifactMetadata(
                id: id,
                fileName: ext.isEmpty ? "content" : "content.\(ext)",
                displayName: source.lastPathComponent,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                kind: kind
            )
            try ArtifactStore.importLegacy(metadata, source: source, into: artifacts)
            try finishLegacyImport(metadata, source: source, artifacts: artifacts)
            recovered += 1
        }
        guard try fm.contentsOfDirectory(atPath: attachments.path).isEmpty else {
            throw ProfileMigrationError.invalidAttachment(attachments.path)
        }
        try fm.removeItem(at: attachments)
        Log.app.info("ProfileMigrator.moveAttachmentsToArtifacts root=\(root.lastPathComponent) references=\(references) recovered=\(recovered)")
    }

    static func renameLibraryToArtifacts(at root: URL) throws {
        let fm = FileManager.default
        let library = root.appendingPathComponent("library", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        guard fm.fileExists(atPath: library.path) else { return }
        if !fm.fileExists(atPath: artifacts.path) {
            try fm.moveItem(at: library, to: artifacts)
            Log.app.info("ProfileMigrator.renameLibraryToArtifacts root=\(root.lastPathComponent) moved=directory")
            return
        }
        let items = try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        for item in items {
            let destination = artifacts.appendingPathComponent(item.lastPathComponent, isDirectory: false)
            if fm.fileExists(atPath: destination.path) {
                guard try equivalent(item, destination) else {
                    throw ProfileMigrationError.collision(destination.path)
                }
                try fm.removeItem(at: item)
            } else {
                try fm.moveItem(at: item, to: destination)
            }
        }
        try fm.removeItem(at: library)
        Log.app.info("ProfileMigrator.renameLibraryToArtifacts root=\(root.lastPathComponent) moved=\(items.count)")
    }

    static func moveChatsIntoDirectories(at root: URL) throws {
        let fm = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: chats.path) else { return }
        let entries = try fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.isRegularFileKey])
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
            let directory = chats.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for source in files {
                let name = source.pathExtension == "json" ? "chat.json" : "turns.jsonl"
                let destination = directory.appendingPathComponent(name, isDirectory: false)
                if fm.fileExists(atPath: destination.path) {
                    guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
                        throw ProfileMigrationError.collision(destination.path)
                    }
                    try fm.removeItem(at: source)
                } else {
                    try fm.moveItem(at: source, to: destination)
                }
                moved += 1
            }
        }
        Log.app.info("ProfileMigrator.moveChatsIntoDirectories root=\(root.lastPathComponent) chats=\(grouped.count) files=\(moved)")
    }

    static func repairStorage(at root: URL) throws {
        try moveAttachmentsToArtifacts(at: root)
        try renameLibraryToArtifacts(at: root)
        try flattenLegacyArtifacts(at: root)
        try migrateLegacySkills(at: root)
        try moveChatsIntoDirectories(at: root)
    }

    static func migrateAgentContexts(at root: URL) throws {
        let fm = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: chats.path) else { return }
        guard let config = ProfileIO.readConfig(at: root) else { throw ProfileMigrationError.missingConfig }
        let scope = ProfileScope(profileID: config.id, root: root, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        let encoder = JSONEncoder()
        let directories = try fm.contentsOfDirectory(
            at: chats,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.sorted { $0.path < $1.path }
        var upgraded = 0
        var refreshed = 0
        for directory in directories {
            let metadataURL = directory.appendingPathComponent("chat.json", isDirectory: false)
            guard fm.fileExists(atPath: metadataURL.path) else { continue }
            var metadata = try decoder.decode(ChatMeta.self, from: Data(contentsOf: metadataURL))
            guard [ChatFormat.currentSchemaVersion, LegacyChatImport.schemaVersion].contains(metadata.schemaVersion) else {
                Log.app.warning("ProfileMigrator.agentContext skipped=\(directory.lastPathComponent) schema=\(metadata.schemaVersion)")
                continue
            }
            let transcriptURL = directory.appendingPathComponent("turns.jsonl", isDirectory: false)
            let lines = fm.fileExists(atPath: transcriptURL.path) ? try transcriptLines(transcriptURL) : []
            let legacy = metadata.schemaVersion == LegacyChatImport.schemaVersion
            let decoded = try lines.map {
                legacy
                    ? try LegacyChatImport.turn(from: $0, decoder: decoder)
                    : try decoder.decode(Turn.self, from: $0)
            }
            let turns = ChatFormat.normalize(decoded)
            if legacy || turns != decoded {
                try blob(turns, encoder: encoder).write(to: transcriptURL, options: .atomic)
            }
            if legacy {
                metadata.schemaVersion = ChatFormat.currentSchemaVersion
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
                    : ChatProjection.makeWireMessages(from: Array(turns[(boundary + 1)...lastAgent]))
                messages = stored.messages + tail
                tokensBefore = stored.tokensBefore
            } else {
                messages = ChatProjection.makeWireMessages(from: Array(turns[...lastAgent]))
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
        Log.app.info("ProfileMigrator.agentContexts root=\(root.lastPathComponent) chats=\(directories.count) refreshed=\(refreshed) upgraded=\(upgraded)")
    }

    static func migrateLegacySkills(at root: URL) throws {
        let count = try SkillFiles.migrateLegacy(at: root)
        guard count > 0 else { return }
        Log.app.info("ProfileMigrator.commandsToSkills root=\(root.lastPathComponent) count=\(count)")
    }

    static func namespaceUserSkills(at root: URL) throws {
        let count = try SkillFiles.migrateUserNamespace(at: root)
        guard count > 0 else { return }
        Log.app.info("ProfileMigrator.namespaceUserSkills root=\(root.lastPathComponent) count=\(count)")
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
                    throw ProfileMigrationError.collision(destination.path)
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
        Log.app.info("ProfileMigrator.removeUserSkillNamespace root=\(root.lastPathComponent) count=\(migrated)")
    }

    private static func finishLegacyImport(_ metadata: ArtifactMetadata, source: URL, artifacts: URL) throws {
        let destination = artifacts
            .appendingPathComponent(metadata.id.uuidString, isDirectory: true)
            .appendingPathComponent(metadata.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw ProfileMigrationError.missingArtifact(destination.path)
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
            throw ProfileMigrationError.collision(destination.path)
        }
        try FileManager.default.removeItem(at: source)
    }

    private static func flattenLegacyArtifacts(at root: URL) throws {
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
            let metadataURL = folder.appendingPathComponent(ArtifactStore.metadataName, isDirectory: false)
            let metadata: ArtifactMetadata
            do {
                metadata = try JSONDecoder().decode(ArtifactMetadata.self, from: Data(contentsOf: metadataURL))
            } catch {
                throw ProfileMigrationError.invalidArtifact(folder.path)
            }
            guard metadata.id.uuidString.caseInsensitiveCompare(folder.lastPathComponent) == .orderedSame,
                  URL(fileURLWithPath: metadata.fileName).lastPathComponent == metadata.fileName else {
                throw ProfileMigrationError.invalidArtifact(folder.path)
            }
            let source = folder.appendingPathComponent(metadata.fileName, isDirectory: false)
            guard fm.fileExists(atPath: source.path) else {
                throw ProfileMigrationError.missingArtifact(source.path)
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
            try rewriteArtifactReferences(in: transcript, replacements: replacements)
        }
        for folder in folders { try fm.removeItem(at: folder) }
        if !folders.isEmpty {
            Log.app.info("ProfileMigrator.flattenLegacyArtifacts root=\(root.lastPathComponent) artifacts=\(folders.count)")
        }
    }

    private static func reusableFilename(suggested: String, id: UUID, data: Data, directory: URL) -> String {
        let cleaned = ArtifactStore.sanitizedFilename(suggested)
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
        let cleaned = ArtifactStore.sanitizedFilename(displayName)
        guard URL(fileURLWithPath: cleaned).pathExtension.isEmpty else { return cleaned }
        let ext = URL(fileURLWithPath: contentName).pathExtension
        return ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
    }

    private static func rewriteArtifactReferences(in transcript: URL, replacements: [String: String]) throws {
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
            let replacement = replaceArtifactReferences(object, replacements: replacements, enabled: false)
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

    private static func replaceArtifactReferences(_ value: Any, replacements: [String: String], enabled: Bool) -> (value: Any, changed: Bool) {
        if let string = value as? String, enabled, let replacement = replacements[string.lowercased()] {
            return (replacement, true)
        }
        if let values = value as? [Any] {
            var changed = false
            let output = values.map {
                let replacement = replaceArtifactReferences($0, replacements: replacements, enabled: enabled)
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
                let replacement = replaceArtifactReferences(child, replacements: replacements, enabled: replaceStrings)
                output[key] = replacement.value
                changed = changed || replacement.changed
            }
            return (output, changed)
        }
        return (value, false)
    }

    private static func transcriptURLs(at root: URL) throws -> [URL] {
        let fm = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: chats.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
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

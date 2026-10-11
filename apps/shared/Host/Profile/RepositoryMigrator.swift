import Foundation
import CryptoKit
import SwiftGitX

nonisolated enum RepositoryMigrator {
    private enum LegacyLocalRepositoryState {
        case main(String)
        case empty
        case unsupported([String])
    }

    static func migrateLegacyLocalRepository(at root: URL, seed: URL?) throws {
        let manager = FileManager.default
        let metadata = root.appendingPathComponent(".git", isDirectory: true)
        guard manager.fileExists(atPath: metadata.path) else { return }
        let headURL = metadata.appendingPathComponent("HEAD", isDirectory: false)
        guard let headData = try? Data(contentsOf: headURL),
              String(decoding: headData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "ref: refs/heads/master"
        else { return }

        switch try legacyLocalRepositoryState(at: root) {
        case .main(let expectedCommit):
            do {
                try Data("ref: refs/heads/main\n".utf8).write(to: headURL, options: .atomic)
                guard try localRepositoryCommit(at: root) == expectedCommit else {
                    throw StorageMigrationError.invalidRepairedLocalRepository
                }
            } catch {
                do {
                    try headData.write(to: headURL, options: .atomic)
                } catch let rollbackError {
                    throw StorageMigrationError.localRepositoryRollbackFailed(rollbackError.localizedDescription)
                }
                throw error
            }
            Log.service.info("StorageMigrator.localRepository repaired=head commit=\(expectedCommit.prefix(12))")
        case .empty:
            guard let seed, manager.fileExists(atPath: seed.path) else {
                throw StorageMigrationError.invalidLocalRepositorySeed
            }
            try replaceLegacyLocalRepositoryMetadata(at: root, metadata: metadata, seed: seed)
            Log.service.info("StorageMigrator.localRepository repaired=seed preservedWorkingTree=true")
        case .unsupported(let references):
            Log.service.warning("StorageMigrator.localRepository skipped references=\(references.joined(separator: ","))")
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
            Log.service.info("StorageMigrator.localServiceManifests saved=\(cleanPaths.count / 2) commit=\(commit.id.abbreviated)")
        } else if hasStagedChanges {
            pendingCount += cleanPaths.count / 2
        }
        if pendingCount > 0 {
            Log.service.info("StorageMigrator.localServiceManifests pending=\(pendingCount)")
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
            Log.service.info("StorageMigrator.localServiceActions saved=\(cleanPaths.count) commit=\(commit.id.abbreviated)")
        }
        if dirtyCount > 0 || (!cleanPaths.isEmpty && hasStagedChanges) {
            Log.service.info("StorageMigrator.localServiceActions pending=\(dirtyCount + (hasStagedChanges ? cleanPaths.count : 0))")
        }
    }

    static func migrateLocalRepositoryVersion(at root: URL) throws {
        let manager = FileManager.default
        let current = root.appendingPathComponent("repository.json", isDirectory: false)
        let packageURL = manager.fileExists(atPath: current.path) ? current : root.appendingPathComponent("ox.json", isDirectory: false)
        guard let data = try? Data(contentsOf: packageURL),
              var package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["version"] as? Int == 1 else { return }
        let repository = try SwiftGitX.Repository.open(at: root)
        guard !repository.isHEADDetached else { return }
        let path = packageURL.lastPathComponent
        let status = try repository.status()
        let dirty = status.contains { [$0.workingTree?.newFile.path, $0.index?.newFile.path].contains(path) }
        let hasStagedChanges = status.contains {
            $0.status.contains(where: {
                [.indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange, .conflicted].contains($0)
            })
        }
        package["version"] = 2
        var output = try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
        output.append(0x0A)
        try output.write(to: packageURL, options: .atomic)
        guard !dirty, !hasStagedChanges else {
            Log.service.info("StorageMigrator.localRepositoryVersion from=1 to=2 pending=true")
            return
        }
        try repository.add(paths: [path])
        let commit = try repository.commit(message: "Upgrade Local services repository to version 2")
        Log.service.info("StorageMigrator.localRepositoryVersion from=1 to=2 commit=\(commit.id.abbreviated)")
    }

    static func prepareRepository(at root: URL, local: Bool) throws -> URL {
        let manager = FileManager.default
        let current = root.appendingPathComponent("repository.json")
        let packageURL = manager.fileExists(atPath: current.path) ? current : root.appendingPathComponent("ox.json")
        let metadata = try packageURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isSymbolicLink != true, (metadata.fileSize ?? 0) <= 512_000 else { throw SkillError.invalidPackage }
        let data = try Data(contentsOf: packageURL)
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = package["version"] as? Int else {
            throw StorageMigrationError.invalidApplicationStorage("repository")
        }
        guard version != 3 else { return root }
        guard version == 2 else { throw StorageMigrationError.invalidApplicationStorage("repository version \(version)") }
        if local {
            let git = try SwiftGitX.Repository.open(at: root)
            if git.isHEADDetached {
                guard try git.status().isEmpty, let commit = try git.HEAD.target as? Commit else {
                    throw StorageMigrationError.invalidApplicationStorage("historical repository with unfinished changes; return to latest")
                }
                let identity = SHA256.hash(data: Data((root.path + commit.id.hex).utf8)).map { String(format: "%02x", $0) }.joined()
                let view = AppStoragePaths.caches.appendingPathComponent("RepositoryViews/\(identity)")
                if manager.fileExists(atPath: view.appendingPathComponent("repository.json").path),
                   let saved = try? JSONSerialization.jsonObject(with: Data(contentsOf: view.appendingPathComponent("repository.json"))) as? [String: Any], saved["version"] as? Int == 3 { return view }
                if manager.fileExists(atPath: view.path) { try manager.removeItem(at: view) }
                try manager.createDirectory(at: view, withIntermediateDirectories: true)
                for file in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) where file.lastPathComponent != ".git" {
                    guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SkillError.invalidPackage }
                    try manager.copyItem(at: file, to: view.appendingPathComponent(file.lastPathComponent))
                }
                try migrateRepositorySkills(at: view)
                return view
            }
        }
        try migrateRepositorySkills(at: root)
        return root
    }

    private static func migrateRepositorySkills(at root: URL) throws {
        let manager = FileManager.default
        let current = root.appendingPathComponent("repository.json")
        let packageURL = manager.fileExists(atPath: current.path) ? current : root.appendingPathComponent("ox.json")
        guard var package = try JSONSerialization.jsonObject(with: Data(contentsOf: packageURL)) as? [String: Any] else { throw SkillError.invalidPackage }
        guard package["version"] as? Int == 2 else { return }
        guard let services = package["services"] as? [String], services.count <= 256 else { throw SkillError.invalidPackage }
        let git = try? SwiftGitX.Repository.open(at: root)
        let clean = try git?.status().isEmpty == true
        let backup = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent)-repository-v2-backup", isDirectory: true)
        if !manager.fileExists(atPath: backup.path) { try manager.createDirectory(at: backup, withIntermediateDirectories: true) }
        let packageBackup = backup.appendingPathComponent(packageURL.lastPathComponent)
        if !manager.fileExists(atPath: packageBackup.path) { try manager.copyItem(at: packageURL, to: packageBackup) }
        var names = Set(package["skills"] as? [String] ?? [])
        var oldDirectories: [String] = []
        var manifests: [(String, Data)] = []
        var moved: [(URL, Skill)] = []
        for service in services {
            let parts = service.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["web", "api", "ios", "mcp"].contains(parts[0]),
                  parts[1].range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else { throw SkillError.invalidPackage }
            let directory = root.appendingPathComponent(parts[0] + "/" + parts[1])
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path == root.resolvingSymlinksInPath().appendingPathComponent(parts[0] + "/" + parts[1]).standardizedFileURL.path else { throw SkillError.invalidPackage }
            let file = directory.appendingPathComponent("service.json")
            guard manager.fileExists(atPath: file.path) else { continue }
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SkillError.invalidPackage }
            let manifestBackup = backup.appendingPathComponent(parts[0] + "/" + parts[1] + "/service.json")
            guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw SkillError.invalidPackage }
            if manifest["skills"] == nil, manager.fileExists(atPath: manifestBackup.path) {
                guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestBackup)) as? [String: Any] else { throw SkillError.invalidPackage }
                manifest = saved
            }
            guard manifest["skills"] == nil || manifest["skills"] is [[String: Any]] else { throw SkillError.invalidPackage }
            let declarations = manifest["skills"] as? [[String: Any]] ?? []
            for declaration in declarations {
                guard let oldName = declaration["name"] as? String, SkillFiles.isLocalName(oldName) else { throw SkillError.invalidPackage }
                let source = directory.appendingPathComponent("skills/\(oldName)")
                let savedSource = backup.appendingPathComponent(parts[0] + "/" + parts[1] + "/skills/" + oldName)
                if !manager.fileExists(atPath: savedSource.path) {
                    try manager.createDirectory(at: savedSource.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: source, to: savedSource)
                }
                guard source.resolvingSymlinksInPath().standardizedFileURL.path == directory.resolvingSymlinksInPath().appendingPathComponent("skills/\(oldName)").standardizedFileURL.path else { throw SkillError.invalidPackage }
                var skill = try SkillFiles.load(directory: manager.fileExists(atPath: source.path) ? source : savedSource)
                oldDirectories.append(parts[0] + "/" + parts[1] + "/skills/" + oldName)
                skill.name = StorageMigrationSupport.migratedSkillName(domain: parts[1], name: oldName)
                skill.instructions = StorageMigrationSupport.migratedSkillInstructions(skill.instructions)
                let dependency = parts[0] == "ios" ? service : parts[1]
                skill.services = Array(Set(skill.services + [dependency])).sorted()
                let destination = root.appendingPathComponent("skills/\(skill.name)")
                if manager.fileExists(atPath: destination.path), try SkillFiles.load(directory: destination) != skill {
                    throw StorageMigrationError.collision("skills/\(skill.name)")
                }
                if moved.contains(where: { $0.1.name == skill.name && $0.1 != skill }) {
                    throw StorageMigrationError.collision("skills/\(skill.name)")
                }
                moved.append((destination, skill))
                names.insert(skill.name)
            }
            if manifest.removeValue(forKey: "skills") != nil {
                manifests.append((parts[0] + "/" + parts[1] + "/service.json", try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])))
            }
        }
        for (relative, _) in manifests {
            let file = root.appendingPathComponent(relative)
            let destination = backup.appendingPathComponent(relative)
            if !manager.fileExists(atPath: destination.path) {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: file, to: destination)
            }
        }
        for (destination, skill) in moved { try SkillFiles.write(skill, directory: destination) }
        for (file, data) in manifests { try data.write(to: root.appendingPathComponent(file), options: .atomic) }
        for directory in oldDirectories.map({ root.appendingPathComponent($0) }) where manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
            let parent = directory.deletingLastPathComponent()
            if (try? manager.contentsOfDirectory(atPath: parent.path).isEmpty) == true { try manager.removeItem(at: parent) }
        }
        package["version"] = 3
        package["skills"] = names.sorted()
        package.removeValue(forKey: "contentHash")
        try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: current, options: .atomic)
        if clean, let git {
            let paths = ["repository.json"] + manifests.map(\.0) + moved.map { "skills/\($0.1.name)" } + oldDirectories
            try git.add(paths: paths)
            let commit = try git.commit(message: "Move shared skills into repository version 3")
            Log.app.info("StorageMigrator.repositorySkills from=2 to=3 count=\(moved.count) commit=\(commit.id.abbreviated)")
        } else {
            Log.app.info("StorageMigrator.repositorySkills from=2 to=3 count=\(moved.count) pending=\(git != nil)")
        }
    }

    static func exportRecoverySource(at source: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ox Recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        _ = try StorageMigrationSupport.copyMigrationSource(from: source, to: destination)
        return destination
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

    private static func legacyLocalRepositoryState(at root: URL) throws -> LegacyLocalRepositoryState {
        let repository = try SwiftGitX.Repository.open(at: root)
        if let main = repository.reference["refs/heads/main"], let commit = main.target as? Commit {
            return .main(commit.id.hex)
        }
        let references = try repository.reference.list().map(\.fullName).sorted()
        return references.isEmpty && repository.isEmpty ? .empty : .unsupported(references)
    }

    private static func replaceLegacyLocalRepositoryMetadata(
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
                _ = try localRepositoryCommit(at: root)
            } catch {
                do {
                    if manager.fileExists(atPath: metadata.path) {
                        try manager.removeItem(at: metadata)
                    }
                    try manager.moveItem(at: backup, to: metadata)
                } catch let rollbackError {
                    throw StorageMigrationError.localRepositoryRollbackFailed(rollbackError.localizedDescription)
                }
                throw error
            }
            do {
                try manager.removeItem(at: backup)
            } catch {
                Log.service.warning("StorageMigrator.localRepository backup cleanup failed error=\(error.localizedDescription)")
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func localRepositoryCommit(at root: URL) throws -> String {
        let repository = try SwiftGitX.Repository.open(at: root)
        guard let head = try repository.HEAD.target as? Commit,
              let main = repository.reference["refs/heads/main"],
              let tip = main.target as? Commit,
              head.id == tip.id else {
            throw StorageMigrationError.invalidRepairedLocalRepository
        }
        return head.id.hex
    }
}

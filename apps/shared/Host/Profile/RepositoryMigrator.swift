import Foundation

nonisolated enum RepositoryMigrator {
    static func migrateRepositoryLocations() throws {
        let manager = FileManager.default
        let source = AppStoragePaths.applicationSupport.appendingPathComponent("service-repositories", isDirectory: true)
        let destination = AppStoragePaths.repositories
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw StorageMigrationError.invalidApplicationStorage("Repositories")
        }
        if manager.fileExists(atPath: AppStoragePaths.repositoryStaging.path) {
            for backup in try manager.contentsOfDirectory(at: AppStoragePaths.repositoryStaging, includingPropertiesForKeys: nil) {
                let prefix = "repository-backup-"
                guard backup.lastPathComponent.hasPrefix(prefix) else { continue }
                let id = String(backup.lastPathComponent.dropFirst(prefix.count))
                guard UUID(uuidString: id) != nil || id == "development" else { continue }
                let original = id == "development" ? AppStoragePaths.developmentRepositorySnapshot : destination.appendingPathComponent(id, isDirectory: true)
                let target = manager.fileExists(atPath: original.path)
                    ? destination.appendingPathComponent("\(id) Copy \(UUID().uuidString)", isDirectory: true)
                    : original
                _ = try StorageMigrationSupport.migrationSourceInventory(at: backup)
                try manager.moveItem(at: backup, to: target)
                Log.service.info("StorageMigrator.repositorySnapshot recovered id=\(id) folder=\(target.lastPathComponent)")
            }
        }
        for directory in try manager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
            guard directory.lastPathComponent == "Local" || UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw StorageMigrationError.invalidApplicationStorage("Repositories/\(directory.lastPathComponent)")
            }
            var target = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try target.setResourceValues(values)
        }
        guard manager.fileExists(atPath: source.path) else { return }
        guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw StorageMigrationError.invalidApplicationStorage("service-repositories")
        }
        for directory in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let id = directory.lastPathComponent
            guard id == "local" || UUID(uuidString: id) != nil else { continue }
            let target = destination.appendingPathComponent(id == "local" ? "Local" : id, isDirectory: true)
            guard !manager.fileExists(atPath: target.path) else {
                throw StorageMigrationError.collision("Repositories/\(target.lastPathComponent)")
            }
            Log.service.info("StorageMigrator.repositoryLocation start id=\(id)")
            let inventory = try StorageMigrationSupport.migrationSourceInventory(at: directory)
            try manager.moveItem(at: directory, to: target)
            guard try StorageMigrationSupport.migrationSourceInventory(at: target) == inventory else {
                throw StorageMigrationError.recoveryRequired("Repository migration could not verify Repositories/\(target.lastPathComponent). Your files have been retained.")
            }
            var backedUpTarget = target
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try backedUpTarget.setResourceValues(values)
            Log.service.info("StorageMigrator.repositoryLocation done id=\(id) files=\(inventory.count)")
        }
    }

    static func migrateLegacyLocalServiceManifests(at root: URL) throws {
        let manager = FileManager.default
        let webRoot = root.appendingPathComponent("web", isDirectory: true)
        guard manager.fileExists(atPath: webRoot.path) else { return }
        var count = 0
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
            try manager.moveItem(at: legacyURL, to: currentURL)
            count += 1
        }
        if count > 0 {
            Log.service.info("StorageMigrator.localServiceManifests migrated=\(count)")
        }
    }

    static func migrateLegacyLocalServiceActions(at root: URL) throws {
        let webRoot = root.appendingPathComponent("web", isDirectory: true)
        guard FileManager.default.fileExists(atPath: webRoot.path) else { return }
        var count = 0
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
            count += 1
        }
        if count > 0 {
            Log.service.info("StorageMigrator.localServiceActions migrated=\(count)")
        }
    }

    static func migrateLocalRepositoryVersion(at root: URL) throws {
        let manager = FileManager.default
        let current = root.appendingPathComponent("repository.json", isDirectory: false)
        let packageURL = manager.fileExists(atPath: current.path) ? current : root.appendingPathComponent("ox.json", isDirectory: false)
        guard let data = try? Data(contentsOf: packageURL),
              var package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["version"] as? Int == 1 else { return }
        package["version"] = 2
        var output = try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
        output.append(0x0A)
        try output.write(to: packageURL, options: .atomic)
        Log.service.info("StorageMigrator.localRepositoryVersion from=1 to=2")
    }

    static func prepareRepository(at root: URL) throws -> URL {
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
        let backup = AppStoragePaths.applicationSupport.appendingPathComponent("RepositoryMigrationBackups/\(root.lastPathComponent)-repository-v2", isDirectory: true)
        let predecessorName = root.lastPathComponent == "Local" ? "local" : root.lastPathComponent
        let predecessorBackup = root.deletingLastPathComponent() == AppStoragePaths.repositories
            ? AppStoragePaths.applicationSupport.appendingPathComponent("service-repositories/.\(predecessorName)-repository-v2-backup", isDirectory: true)
            : root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent)-repository-v2-backup", isDirectory: true)
        if !manager.fileExists(atPath: backup.path), manager.fileExists(atPath: predecessorBackup.path) {
            try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try StorageMigrationSupport.migrationSourceInventory(at: predecessorBackup)
            try manager.moveItem(at: predecessorBackup, to: backup)
        }
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
        Log.app.info("StorageMigrator.repositorySkills from=2 to=3 count=\(moved.count)")
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
}

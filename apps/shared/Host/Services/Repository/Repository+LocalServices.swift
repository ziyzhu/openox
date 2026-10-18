import Foundation

extension Repository {
    func saveSkill(_ skill: Skill, replacing: String? = nil, createOnly: Bool = false) throws {
        try prepareLocalMutation()
        guard !SkillFiles.reservedNames.contains(skill.name) else { throw SkillError.reserved(skill.name) }
        try SkillFiles.validate(skill)
        var package = try Self.loadPackage(at: localRoot, provenance: .local)
        let destination = localRoot.appendingPathComponent("skills/\(skill.name)")
        if (createOnly || replacing != nil && replacing != skill.name), FileManager.default.fileExists(atPath: destination.path) {
            throw SkillError.exists(skill.name)
        }
        if let replacing { guard SkillFiles.isLocalName(replacing) else { throw SkillError.invalidName } }
        try SkillFiles.write(skill, directory: destination)
        if let replacing, replacing != skill.name { package.skills.removeAll { $0 == replacing } }
        if !package.skills.contains(skill.name) { package.skills.append(skill.name) }
        package.skills.sort()
        try Self.writePackage(package, at: localRoot)
        if let replacing, replacing != skill.name {
            try FileManager.default.removeItem(at: localRoot.appendingPathComponent("skills/\(replacing)"))
        }
        Log.service.info("Repository.skill save name=\(skill.name)")
    }

    func deleteSkill(name: String) throws {
        try prepareLocalMutation()
        guard SkillFiles.isLocalName(name) else { throw SkillError.invalidName }
        var package = try Self.loadPackage(at: localRoot, provenance: .local)
        guard package.skills.contains(name) else { throw SkillError.missing(name) }
        package.skills.removeAll { $0 == name }
        try Self.writePackage(package, at: localRoot)
        try FileManager.default.removeItem(at: localRoot.appendingPathComponent("skills/\(name)"))
        Log.service.info("Repository.skill delete name=\(name)")
    }

    func createService(kind: ServiceKind, id: String) throws {
        guard [.web, .api].contains(kind) else {
            throw Failure(message: "Only Local web and API services can be created.")
        }
        try createScriptService(kind: kind, domain: id)
    }

    private func createScriptService(kind: ServiceKind, domain: String) throws {
        guard Self.isServiceID(domain), kind == .api || domain.contains(".") else {
            throw Failure(message: "Use a lowercase website domain for the Local service.")
        }
        try prepareLocalMutation()
        var package = try Self.loadPackage(at: localRoot, provenance: .local)
        guard !package.services.contains(where: { $0.id.runtimeID == domain }) else {
            throw Failure(message: "A Local service already exists for \(domain).")
        }
        let service = Package.Service(id: try ServiceID(kind: kind, runtimeID: domain))
        let serviceRoot = localRoot.appendingPathComponent(service.id.path, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: serviceRoot.path) else {
            throw Failure(message: "Local source already exists for \(domain).")
        }
        do {
            try FileManager.default.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
            var manifest: [String: Any] = [
                "domain": domain,
                "name": domain,
                "description": "Local service for \(domain).",
                "baseUrl": "https://\(domain)/",
                "actions": [],
            ]
            if kind == .api {
                manifest["kind"] = "api"
                manifest["auth"] = ["type": "none"]
                manifest["baseUrl"] = "https://example.com/"
            }
            var manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            manifestData.append(0x0A)
            try manifestData.write(to: serviceRoot.appendingPathComponent("service.json"), options: .atomic)
            try Data("window.ox.install(() => {});\n".utf8)
                .write(to: serviceRoot.appendingPathComponent("actions.js"), options: .atomic)
            package.services.append(service)
            package.services.sort { $0.id.rawValue.localizedStandardCompare($1.id.rawValue) == .orderedAscending }
            try Self.writePackage(package, at: localRoot)
            _ = try Self.loadPackage(at: localRoot, provenance: .local)
        } catch {
            try? FileManager.default.removeItem(at: serviceRoot)
            throw error
        }
        configuration.resolutions[domain] = Self.localID
        try saveConfiguration()
        Log.service.info("Repository.local create domain=\(domain)")
    }

    func saveMCPService(_ manifest: MCPCatalogManifest, creating: Bool) throws {
        guard manifest.isValid else { throw Failure(message: "Invalid MCP manifest.") }
        try prepareLocalMutation()
        var package = try Self.loadPackage(at: localRoot, provenance: .local)
        let service = Package.Service(id: try ServiceID(kind: .mcp, runtimeID: manifest.id))
        let serviceRoot = localRoot.appendingPathComponent(service.id.path, isDirectory: true)
        let exists = package.services.contains { $0.id == service.id }
        guard exists != creating, !creating || !FileManager.default.fileExists(atPath: serviceRoot.path) else {
            throw Failure(message: creating ? "A Local service already exists for \(manifest.id)." : "No Local MCP service exists for \(manifest.id).")
        }
        do {
            try FileManager.default.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
            try manifest.encoded().write(to: serviceRoot.appendingPathComponent("service.json"), options: .atomic)
            if creating {
                package.services.append(service)
                package.services.sort { $0.id.rawValue.localizedStandardCompare($1.id.rawValue) == .orderedAscending }
                try Self.writePackage(package, at: localRoot)
            }
        } catch {
            if creating { try? FileManager.default.removeItem(at: serviceRoot) }
            throw error
        }
        if creating {
            configuration.resolutions[manifest.id] = Self.localID
            try saveConfiguration()
        }
        Log.service.info("Repository.local saveMCP id=\(manifest.id) created=\(creating)")
    }

    func copyServiceToLocal(id: String) throws {
        try prepareLocalMutation()
        guard let source = activeSources[id] else { throw Failure(message: "Service not found") }
        guard source.provenance != .local else { return }
        guard source.kind != .iOS else { throw Failure(message: "Native iOS services cannot be copied to Local.") }
        var package = try Self.loadPackage(at: localRoot, provenance: .local)
        guard !package.services.contains(where: { $0.id.runtimeID == id }) else {
            throw Failure(message: "A Local service already exists for \(id). Use ox.repository.conflicts and ox.repository.resolve to select it without replacing its files.")
        }
        let service = Package.Service(id: try ServiceID(kind: source.kind, runtimeID: id))
        let destination = localRoot.appendingPathComponent(service.id.path, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure(message: "Local source already exists for \(id).")
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.root, to: destination)
            package.services.append(service)
            package.services.sort { $0.id.rawValue.localizedStandardCompare($1.id.rawValue) == .orderedAscending }
            try Self.writePackage(package, at: localRoot)
            _ = try Self.loadPackage(at: localRoot, provenance: .local)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        configuration.resolutions[id] = Self.localID
        try saveConfiguration()
        Log.service.info("Repository.local copy id=\(id) source=\(source.repositoryID)")
    }

    func exportLocalService(id: String) throws -> Data {
        let package = try Self.loadPackage(at: localRoot, provenance: .local)
        guard let service = package.services.first(where: { $0.id.runtimeID == id }),
              service.id.kind == .web || service.id.kind == .api else {
            throw Failure(message: "Only Local web and API services can be shared.")
        }
        let source = try localSource(kind: service.id.kind, id: id)
        try Self.validateService(service, root: localRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: source.root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw Failure(message: "Local service source is unavailable.") }
        var files: [ZipArchiveCodec.File] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure(message: "Service source contains a symbolic link.") }
            guard values.isRegularFile == true else { continue }
            let path = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            files.append(.init(path: "services/\(service.id.path)/\(path)", data: try Data(contentsOf: url)))
        }
        let data = try ServicePackageCodec.encode(kind: service.id.kind, domain: id, files: files.sorted { $0.path < $1.path })
        Log.service.info("Repository.export id=\(service.id.rawValue) files=\(files.count) bytes=\(data.count)")
        return data
    }

    func importLocalService(_ payload: ServicePackagePayload, replacing: Bool) throws {
        try prepareLocalMutation()
        let originalPackage = try Self.loadPackage(at: localRoot, provenance: .local)
        let service = Package.Service(id: try ServiceID(kind: payload.kind, runtimeID: payload.domain))
        let existing = originalPackage.services.first(where: { $0.id.runtimeID == payload.domain })
        guard existing == nil || replacing else {
            throw Failure(message: "A Local service already exists for \(payload.domain).")
        }
        guard existing == nil || existing?.id.kind == payload.kind else {
            throw Failure(message: "A different Local service already uses \(payload.domain).")
        }
        guard existing != nil || !replacing else {
            throw Failure(message: "There is no Local service to replace.")
        }
        let destination = localRoot.appendingPathComponent(service.id.path, isDirectory: true)
        guard existing != nil || !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure(message: "Local source already exists for \(payload.domain).")
        }
        try FileManager.default.createDirectory(at: AppStoragePaths.repositoryStaging, withIntermediateDirectories: true)
        let staging = AppStoragePaths.repositoryStaging.appendingPathComponent("importing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedService = staging.appendingPathComponent(service.id.path, isDirectory: true)
        let backup = AppStoragePaths.repositoryStaging.appendingPathComponent("replaced-\(UUID().uuidString)", isDirectory: true)
        let originalConfiguration = configuration
        var updatedPackage = originalPackage
        if existing == nil {
            updatedPackage.services.append(service)
            updatedPackage.services.sort { $0.id.rawValue < $1.id.rawValue }
        }
        do {
            for file in payload.files {
                guard file.path.hasPrefix(payload.sourcePrefix) else { throw ServicePackageError.invalidSource }
                let path = String(file.path.dropFirst("services/".count))
                let target = staging.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: target, options: .atomic)
            }
            try Self.validateService(service, root: staging)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if existing != nil { try FileManager.default.moveItem(at: destination, to: backup) }
            try FileManager.default.moveItem(at: stagedService, to: destination)
            if existing == nil { try Self.writePackage(updatedPackage, at: localRoot) }
            _ = try Self.loadPackage(at: localRoot, provenance: .local)
            configuration.resolutions[payload.domain] = Self.localID
            try saveConfiguration()
            if existing != nil { try FileManager.default.removeItem(at: backup) }
            Log.service.info("Repository.import id=\(service.id.rawValue) files=\(payload.files.count) replaced=\(existing != nil)")
        } catch {
            Log.service.error("Repository.import failed id=\(service.id.rawValue) destination=\(destination.path) backup=\(backup.path) error=\(Self.errorMessage(error))")
            configuration = originalConfiguration
            attemptRollback(serviceID: service.id.rawValue, step: "import.configuration", path: configurationURL) {
                try saveConfiguration()
            }
            if existing == nil {
                attemptRollback(serviceID: service.id.rawValue, step: "import.package", path: localRoot) {
                    try Self.writePackage(originalPackage, at: localRoot)
                }
            }
            if FileManager.default.fileExists(atPath: backup.path) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    attemptRollback(serviceID: service.id.rawValue, step: "import.remove-replacement", path: destination) {
                        try FileManager.default.removeItem(at: destination)
                    }
                }
                attemptRollback(serviceID: service.id.rawValue, step: "import.restore-source", path: backup) {
                    try FileManager.default.moveItem(at: backup, to: destination)
                }
            } else if existing == nil, FileManager.default.fileExists(atPath: destination.path) {
                attemptRollback(serviceID: service.id.rawValue, step: "import.remove-source", path: destination) {
                    try FileManager.default.removeItem(at: destination)
                }
            }
            throw error
        }
    }

    func deleteLocalService(id: String) throws -> ServiceKind {
        try prepareLocalMutation()
        let originalPackage = try Self.loadPackage(at: localRoot, provenance: .local)
        guard let index = originalPackage.services.firstIndex(where: { $0.id.runtimeID == id }) else {
            throw Failure(message: "No Local service exists for \(id).")
        }
        let service = originalPackage.services[index]
        let serviceRoot = localRoot.appendingPathComponent(service.id.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: serviceRoot.path) else {
            throw Failure(message: "Local source does not exist for \(id).")
        }
        try FileManager.default.createDirectory(at: AppStoragePaths.repositoryStaging, withIntermediateDirectories: true)
        let staging = AppStoragePaths.repositoryStaging.appendingPathComponent("deleting-\(UUID().uuidString)", isDirectory: true)
        var package = originalPackage
        package.services.remove(at: index)
        let originalConfiguration = configuration
        do {
            try FileManager.default.moveItem(at: serviceRoot, to: staging)
            try Self.writePackage(package, at: localRoot)
            _ = try Self.loadPackage(at: localRoot, provenance: .local)
            if configuration.resolutions[id] == Self.localID {
                configuration.resolutions.removeValue(forKey: id)
                try saveConfiguration()
            }
            try FileManager.default.removeItem(at: staging)
        } catch {
            Log.service.error("Repository.local delete failed id=\(service.id.rawValue) source=\(serviceRoot.path) staging=\(staging.path) error=\(Self.errorMessage(error))")
            configuration = originalConfiguration
            attemptRollback(serviceID: service.id.rawValue, step: "delete.configuration", path: configurationURL) {
                try saveConfiguration()
            }
            attemptRollback(serviceID: service.id.rawValue, step: "delete.package", path: localRoot) {
                try Self.writePackage(originalPackage, at: localRoot)
            }
            if FileManager.default.fileExists(atPath: staging.path) {
                attemptRollback(serviceID: service.id.rawValue, step: "delete.restore-source", path: staging) {
                    try FileManager.default.moveItem(at: staging, to: serviceRoot)
                }
            }
            throw error
        }
        Log.service.info("Repository.local delete id=\(id) kind=\(service.id.kind.rawValue)")
        return service.id.kind
    }

    private func attemptRollback(serviceID: String, step: String, path: URL, _ rollback: () throws -> Void) {
        do {
            try rollback()
        } catch {
            Log.service.error("Repository.rollback failed id=\(serviceID) step=\(step) path=\(path.path) error=\(Self.errorMessage(error))")
        }
    }

    private static func isServiceID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9]+(?:[.:-][a-z0-9]+)*$", options: .regularExpression) != nil
    }
}

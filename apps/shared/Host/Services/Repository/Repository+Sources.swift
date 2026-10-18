import Foundation

extension Repository {
    func source(domain: String) async -> Source? {
        guard let source = activeSources[domain] else { return nil }
        if source.provenance == .mounted {
            do {
                guard let record = try mountedRepositories.records().first(where: { $0.id == source.repositoryID }) else { return nil }
                return try await DeviceFolderStore.shared.coordinate(
                    grantID: record.grantID,
                    relativePath: record.relativePath + [source.kind.rawValue, domain, "actions.js"],
                    profileId: await StorageRoot.shared.activeId, mode: .read
                ) { url in Source(actions: try String(contentsOf: url, encoding: .utf8)) }
            } catch {
                Log.service.error("Repository.mounted source unavailable domain=\(domain) error=\(error.localizedDescription)")
                return nil
            }
        }
        guard let actions = try? String(contentsOf: source.root.appendingPathComponent("actions.js"), encoding: .utf8) else { return nil }
        return Source(actions: actions)
    }

    func listSource(kind: ServiceKind, id: String, path: [String]) async throws -> [Entry] {
        let source = try activeSource(kind: kind, id: id)
        if source.provenance == .mounted { try await requireMountedAccess(source.repositoryID) }
        if !source.provenance.exposesFullSource {
            guard path.isEmpty else { throw Failure(message: "Full service source is available only for Bundled and Local services.") }
            let manifest = Self.serviceManifestURL(at: source.root)
            let size = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return [Entry(name: "service.json", isDirectory: false, size: size)]
        }
        let directory = try sourceURL(source, path: path)
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure(message: "Not a service directory.")
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return nil }
            if values.isDirectory == true { return Entry(name: url.lastPathComponent, isDirectory: true, size: nil) }
            if values.isRegularFile == true {
                if url.lastPathComponent == "manifest.json",
                   FileManager.default.fileExists(atPath: directory.appendingPathComponent("service.json").path) {
                    return nil
                }
                let name = url.lastPathComponent == "manifest.json" ? "service.json" : url.lastPathComponent
                return Entry(name: name, isDirectory: false, size: values.fileSize)
            }
            return nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func sourceIsDirectory(kind: ServiceKind, id: String, path: [String]) async throws -> Bool {
        let source = try activeSource(kind: kind, id: id)
        if source.provenance == .mounted { try await requireMountedAccess(source.repositoryID) }
        guard source.provenance.exposesFullSource || path.isEmpty else { return false }
        return try sourceURL(source, path: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    func readSource(kind: ServiceKind, id: String, path: [String]) async throws -> Data {
        let source = try activeSource(kind: kind, id: id)
        if source.provenance == .mounted { try await requireMountedAccess(source.repositoryID) }
        guard source.provenance.exposesFullSource || path == ["service.json"] else {
            throw Failure(message: "Full service source is available only for Bundled and Local services.")
        }
        return try readSource(source, path: path)
    }

    func readLocalSource(kind: ServiceKind, id: String, path: [String]) throws -> Data {
        try readSource(localSource(kind: kind, id: id), path: path)
    }

    private func readSource(_ source: ActiveSource, path: [String]) throws -> Data {
        let url = try sourceURL(source, path: path, legacyFallback: true)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure(message: "Not a service file.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= VirtualFileSystem.maximumReadBytes else {
            throw Failure(message: "Service file is too large.")
        }
        return data
    }

    func writeLocalSource(kind: ServiceKind, id: String, path: [String], data: Data) throws {
        let source = try editableSource(kind: kind, id: id)
        guard data.count <= VirtualFileSystem.maximumReadBytes else { throw Failure(message: "Service file is too large.") }
        let url = try sourceURL(source, path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        Log.service.info("Repository.local write id=\(id) path=\(path.joined(separator: "/")) bytes=\(data.count)")
    }

    func updateLocalManifest(kind: ServiceKind, id: String, fields: [String: JSONValue]) throws {
        let source = try editableSource(kind: kind, id: id)
        let data = try readSource(source, path: ["service.json"])
        guard var manifest = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            throw Failure(message: "Invalid service manifest.")
        }
        for (key, value) in fields {
            if value == .null {
                manifest.removeValue(forKey: key)
            } else {
                manifest[key] = value
            }
        }
        let definition = try ServiceDefinition(manifest: .object(manifest), repositoryID: Self.localID, provenance: .local)
        guard definition.domain == id, definition.isAPI == (kind == .api) else {
            throw Failure(message: "Manifest identity does not match its directory.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeLocalSource(kind: kind, id: id, path: ["service.json"], data: encoder.encode(JSONValue.object(manifest)))
        Log.service.info("Repository.local update id=\(id) kind=\(kind.rawValue) fields=\(fields.keys.sorted().joined(separator: ","))")
    }

    func deleteLocalSource(kind: ServiceKind, id: String, path: [String]) throws {
        let source = try editableSource(kind: kind, id: id)
        let url = try sourceURL(source, path: path)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure(message: "Only Local service files can be deleted.")
        }
        try FileManager.default.removeItem(at: url)
        Log.service.info("Repository.local delete id=\(id) path=\(path.joined(separator: "/"))")
    }

    func validateLocalSource(kind: ServiceKind, id: String) throws {
        _ = try localSource(kind: kind, id: id)
        try Self.validateService(Package.Service(id: ServiceID(kind: kind, runtimeID: id)), root: localRoot)
    }

    func localSource(kind: ServiceKind, id: String) throws -> ActiveSource {
        if let message = localPreparation?.failureMessage { throw Failure(message: message) }
        let package = try Self.loadPackage(at: localRoot, provenance: .local)
        guard let service = package.services.first(where: { $0.id.kind == kind && $0.id.runtimeID == id }) else {
            throw Failure(message: "No Local service exists for \(id).")
        }
        return ActiveSource(kind: kind, root: localRoot.appendingPathComponent(service.id.path), repositoryID: Self.localID, provenance: .local)
    }

    func sourcePaths(kind: ServiceKind, id: String) async throws -> [String] {
        let source = try activeSource(kind: kind, id: id)
        if source.provenance == .mounted { try await requireMountedAccess(source.repositoryID) }
        if !source.provenance.exposesFullSource { return ["services/\(kind.rawValue)/\(id)/service.json"] }
        guard let enumerator = FileManager.default.enumerator(
            at: source.root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            var relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            if relative == "manifest.json" {
                if FileManager.default.fileExists(atPath: source.root.appendingPathComponent("service.json").path) { continue }
                relative = "service.json"
            }
            paths.append("services/\(kind.rawValue)/\(id)/\(relative)")
            if paths.count >= VirtualFileSystem.maximumSearchFiles { break }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func activeSource(kind: ServiceKind, id: String) throws -> ActiveSource {
        if activeSources[id]?.provenance == .local, let message = localPreparation?.failureMessage { throw Failure(message: message) }
        guard let source = activeSources[id], source.kind == kind else { throw Failure(message: "Service not found") }
        return source
    }

    private func editableSource(kind: ServiceKind, id: String) throws -> ActiveSource {
        let source = try activeSource(kind: kind, id: id)
        guard source.provenance == .local else {
            throw Failure(message: "Only Local services are editable. Copy this service to Local before editing it.")
        }
        try prepareLocalMutation()
        return source
    }

    func sourceURL(_ source: ActiveSource, path: [String], legacyFallback: Bool = false) throws -> URL {
        guard path.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\")
        }) else {
            throw Failure(message: "Invalid service path")
        }
        var url = path.reduce(source.root) { $0.appendingPathComponent($1) }.standardizedFileURL
        if legacyFallback, path == ["service.json"], !FileManager.default.fileExists(atPath: url.path) {
            let legacy = source.root.appendingPathComponent("manifest.json").standardizedFileURL
            if FileManager.default.fileExists(atPath: legacy.path) { url = legacy }
        }
        guard url.path == source.root.standardizedFileURL.path
                || url.path.hasPrefix(source.root.standardizedFileURL.path + "/") else {
            throw Failure(message: "Service path escapes its repository")
        }
        let repositoryRoot = source.root.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let expectedRoot = repositoryRoot.appendingPathComponent(source.kind.rawValue).appendingPathComponent(source.root.lastPathComponent)
        guard source.root.resolvingSymlinksInPath().standardizedFileURL.path == expectedRoot.standardizedFileURL.path else {
            throw Failure(message: "Symbolic links are not supported")
        }
        var ancestor = url
        while ancestor.path != source.root.standardizedFileURL.path {
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw Failure(message: "Symbolic links are not supported")
            }
            ancestor.deleteLastPathComponent()
        }
        return url
    }
}

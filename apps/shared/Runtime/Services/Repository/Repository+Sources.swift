import CryptoKit
import Foundation

extension Repository {
    func compareSources(service: String) async throws -> JSONValue {
        guard let sources = candidateSources[service], sources.count > 1 else {
            throw Failure(message: "Service source conflict is no longer available; inspect conflicts again.")
        }
        var candidates: [JSONValue] = []
        var fileSets: [[String: String]] = []
        for source in sources {
            if source.provenance == .mounted { try await requireMountedAccess(source.repositoryID) }
            _ = try readSource(source, path: ["service.json"])
            var files: [JSONValue] = []
            var hashes: [String: String] = [:]
            guard try Self.forEachFile(in: source.root, options: [], { _, values, path in
                guard values.isSymbolicLink != true else { throw Failure(message: "Symbolic links are not supported") }
                guard values.isRegularFile == true else { return true }
                let data = try readSource(source, path: path.split(separator: "/").map(String.init))
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                hashes[path] = hash
                files.append(.object(["path": .string(path), "bytes": .int(data.count), "sha256": .string(hash)]))
                return true
            }) else { throw Failure(message: "Service source directory is unavailable.") }
            fileSets.append(hashes)
            candidates.append(.object([
                "repository": .string(source.repositoryID),
                "files": .array(files.sorted { ($0.objectValue?["path"]?.stringValue ?? "") < ($1.objectValue?["path"]?.stringValue ?? "") }),
            ]))
        }
        return .object([
            "identical": .bool(fileSets.dropFirst().allSatisfy { $0 == fileSets.first }),
            "candidates": .array(candidates),
        ])
    }

    func source(domain: String) async -> Source? {
        guard let source = activeSources[domain] else { return nil }
        if source.provenance == .mounted {
            do {
                guard let record = try mountedRecord(source.repositoryID) else { return nil }
                return try await DeviceFolderStore.shared.coordinate(
                    grantID: record.grantID,
                    relativePath: record.relativePath + [source.kind.rawValue, domain, "actions.js"],
                    profileId: await StorageRoot.shared.activeId, mode: .read
                ) { url in
                    Source(actions: try String(contentsOf: url, encoding: .utf8), version: try Self.sourceVersion(domain: domain, source: source))
                }
            } catch {
                Log.service.error("Repository.mounted source unavailable domain=\(domain) error=\(error.localizedDescription)")
                return nil
            }
        }
        guard let actions = try? String(contentsOf: source.root.appendingPathComponent("actions.js"), encoding: .utf8),
              let version = try? Self.sourceVersion(domain: domain, source: source) else { return nil }
        return Source(actions: actions, version: version)
    }

    private static func sourceVersion(domain: String, source: ActiveSource) throws -> String {
        let service = Package.Service(id: try ServiceID(kind: source.kind, runtimeID: domain))
        let root = source.root.deletingLastPathComponent().deletingLastPathComponent()
        let hash = try serviceContentHash(at: root, service: service, provenance: source.provenance)
        return "\(service.id.rawValue):\(source.repositoryID):\(hash)"
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

    func sourceURL(_ source: ActiveSource, path: [String], legacyFallback: Bool = false) throws -> URL {
        guard path.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && ![".ox", ".files"].contains($0.lowercased()) && !$0.lowercased().hasPrefix(".stage-") && !$0.lowercased().hasPrefix(".ox-stage-") && !$0.contains("/") && !$0.contains("\\")
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

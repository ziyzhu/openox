import Foundation

extension Repository {
    func localServiceKind(_ id: String) throws -> ServiceKind? {
        try Self.loadPackage(at: localRoot, provenance: .local).services.first { $0.id.runtimeID == id }?.id.kind
    }

    func requireWritableRepository(_ id: String, path: [String]) throws {
        guard id == Self.localID, !path.isEmpty else {
            throw OxFunctionError(code: "permission_denied", message: "Only files inside the Local repository are writable.", recovery: "Copy source into repositories/local/ before editing it.")
        }
        if let message = localPreparation?.failureMessage { throw Failure(message: message) }
    }

    func withRepositoryFile<T: Sendable>(
        _ id: String,
        path: [String],
        profileID: UUID? = nil,
        write: Bool = false,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        if write { try requireWritableRepository(id, path: path) }
        guard path.allSatisfy(Self.isPublicRepositoryComponent) else {
            throw Failure(message: "Invalid repository path")
        }
        if let record = try mountedRecord(id) {
            return try await DeviceFolderStore.shared.coordinate(
                grantID: record.grantID,
                relativePath: record.relativePath,
                profileId: profileID,
                mode: .read
            ) { root in
                try body(Self.repositoryFileURL(root: root, path: path))
            }
        }
        let root: URL
        if id == Self.localID {
            if let message = localPreparation?.failureMessage { throw Failure(message: message) }
            root = localRoot
        } else {
            guard let available = fileRoots[id] else { throw Failure(message: "Repository is unavailable.") }
            root = available
        }
        let url = try Self.repositoryFileURL(root: root, path: path)
        return try body(url)
    }

    static func isPublicRepositoryComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
    }

    private static func repositoryFileURL(root: URL, path: [String]) throws -> URL {
        var url = root.standardizedFileURL
        for component in path {
            url.appendPathComponent(component)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                throw Failure(message: "Symbolic links are not supported")
            }
        }
        return url
    }

    func listRepositoryFiles(_ id: String, path: [String], profileID: UUID?) async throws -> [Entry] {
        try await withRepositoryFile(id, path: path, profileID: profileID) { directory in
            try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ).compactMap { url in
                guard Self.isPublicRepositoryComponent(url.lastPathComponent) else { return nil }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { return nil }
                return Entry(name: url.lastPathComponent, isDirectory: values.isDirectory == true, size: values.fileSize)
            }
        }
    }

    func repositoryFileIsDirectory(_ id: String, path: [String], profileID: UUID?) async throws -> Bool {
        try await withRepositoryFile(id, path: path, profileID: profileID) { url in
            try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
    }

    func readRepositoryFile(_ id: String, path: [String], profileID: UUID?) async throws -> Data {
        try await withRepositoryFile(id, path: path, profileID: profileID) { url in
            try Self.validateRegularFile(url, maximumSize: VirtualFileSystem.maximumReadBytes)
            return try Data(contentsOf: url)
        }
    }

    func writeRepositoryFile(_ id: String, path: [String], data: Data) async throws {
        guard data.count <= VirtualFileSystem.maximumReadBytes else { throw Failure(message: "Repository file is too large.") }
        if path == ["repository.json"] {
            try Self.validatePackageShape(data)
            let package = try JSONDecoder().decode(Package.self, from: data)
            guard data.count <= 512_000, HostProtocols.repository.contains(package.version),
                  !package.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, package.name.count <= 100,
                  package.contentHash == nil || package.contentHash?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  package.services.count <= 256, package.skills.count <= 256,
                  Set(package.services.map { $0.id.runtimeID }).count == package.services.count,
                  package.services.allSatisfy({ $0.id.kind != .iOS }),
                  Set(package.skills).count == package.skills.count,
                  package.skills.allSatisfy({ SkillFiles.isLocalName($0) && !SkillFiles.reservedNames.contains($0) }) else {
                throw Failure(message: "Invalid Local repository manifest.")
            }
        }
        try await withRepositoryFile(id, path: path, write: true) { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        Log.service.info("Repository.files write repository=\(id) path=\(path.joined(separator: "/")) bytes=\(data.count)")
    }

    func createRepositoryDirectory(_ id: String, path: [String], recursive: Bool) async throws {
        try await withRepositoryFile(id, path: path, write: true) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: recursive)
        }
    }

    func removeRepositoryFile(_ id: String, path: [String], recursive: Bool) async throws {
        if path.count <= 2, let kind = path.first, ServiceKind(rawValue: kind) != nil {
            throw Failure(message: "Use ox.service.delete to remove a service and its runtime state.")
        }
        guard path != ["repository.json"] else { throw Failure(message: "The repository manifest cannot be deleted.") }
        try await withRepositoryFile(id, path: path, write: true) { url in
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true, !recursive,
               try !FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty {
                throw Failure(message: "Directory is not empty; recursive removal is required.")
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        Log.service.info("Repository.files trash repository=\(id) path=\(path.joined(separator: "/")) recursive=\(recursive)")
    }

    func transferRepositoryFile(from repository: String, path: [String], to destination: String, destinationPath: [String], copy: Bool, profileID: UUID?) async throws {
        try requireWritableRepository(destination, path: destinationPath)
        if !copy { try requireWritableRepository(repository, path: path) }
        guard !path.isEmpty, !destinationPath.isEmpty, destinationPath != ["repository.json"],
              !(repository == destination && destinationPath.starts(with: path)) else {
            throw Failure(message: "Cannot transfer a repository root or copy into the source tree.")
        }
        if !copy && (path == ["repository.json"] || path.count <= 2) {
            throw Failure(message: "Service and repository roots cannot be moved.")
        }
        try await withRepositoryFile(destination, path: destinationPath, write: true) { target in
            guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure(message: "Destination already exists.") }
        }
        let destinationRoot = localRoot
        try await withRepositoryFile(repository, path: path, profileID: profileID) { source in
            let target = try Self.repositoryFileURL(root: destinationRoot, path: destinationPath)
            var count = 0
            var bytes = 0
            if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try Self.forEachFile(in: source, options: []) { _, values, relative in
                    count += 1
                    bytes += values.fileSize ?? 0
                    guard count <= VirtualFileSystem.maximumSearchFiles, bytes <= VirtualFileSystem.maximumReadBytes,
                          values.isSymbolicLink != true,
                          relative.split(separator: "/").allSatisfy({ Self.isPublicRepositoryComponent(String($0)) }) else {
                        throw Failure(message: "Source contains private files, symbolic links, or exceeds copy limits.")
                    }
                    return true
                }
            } else {
                try Self.validateRegularFile(source, maximumSize: VirtualFileSystem.maximumReadBytes)
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if copy { try FileManager.default.copyItem(at: source, to: target) }
            else { try FileManager.default.moveItem(at: source, to: target) }
        }
        Log.service.info("Repository.files transfer source=\(repository) from=\(path.joined(separator: "/")) destination=\(destination) to=\(destinationPath.joined(separator: "/")) copy=\(copy)")
    }
}

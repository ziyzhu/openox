import CryptoKit
import Foundation
import SwiftGitX

actor ServiceRepository {
    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
        let size: Int?
    }

    enum ServiceKind: String, Codable, Sendable {
        case web
        case iOS = "ios"
        case mcp
    }

    struct ManifestFile: Sendable {
        let repositoryID: String
        let provenance: Repository.Provenance
        let domain: String
        let data: Data
    }

    struct RepositoryManifestFile: Sendable {
        let repositoryID: String
        let provenance: Repository.Provenance
        let id: String
        let data: Data
    }

    struct Source: Sendable {
        let actions: String
        let skills: [String: String]
    }

    struct ServiceReference: Identifiable, Equatable, Sendable {
        let id: String
        let runtimeID: String
    }

    struct Repository: Identifiable, Equatable, Sendable {
        enum Provenance: String, Codable, Sendable {
            case bundled
            case local
            case development
            case remote

            var selectionPriority: Int {
                switch self {
                case .bundled: 0
                case .local: 1
                case .development: 2
                case .remote: 3
                }
            }
        }

        enum State: Equatable, Sendable {
            case ready
            case failed(String)
        }

        enum View: String, Equatable, Sendable {
            case live
            case historical
        }

        let id: String
        let name: String
        let origin: URL?
        let commitHash: String?
        let tipCommitHash: String?
        let view: View
        let lastSyncedAt: Date?
        let isEnabled: Bool
        let provenance: Provenance
        let serviceCount: Int
        let services: [ServiceReference]
        let state: State
    }

    struct Conflict: Identifiable, Equatable, Sendable {
        struct Candidate: Identifiable, Equatable, Sendable {
            let id: String
            let repositoryID: String
            let repositoryName: String
        }

        let id: String
        let serviceID: String
        let candidates: [Candidate]
        let selectedRepositoryID: String?
    }

    struct MonoRepository: Sendable {
        let repositories: [Repository]
        let conflicts: [Conflict]
        let webManifests: [ManifestFile]
        let iOSManifests: [RepositoryManifestFile]
        let mcpManifests: [RepositoryManifestFile]
        let hash: String
    }

    struct GitStatus: Encodable, Sendable {
        let repository: String
        let provenance: String
        let view: String
        let commitHash: String
        let tipCommitHash: String
        let staged: [String]
        let unstaged: [String]
        let untracked: [String]
        let dirty: Bool
    }

    struct GitCommit: Encodable, Sendable {
        let commitHash: String
        let parentCommitHash: String?
        let summary: String
        let message: String
        let committedAt: String
    }

    struct GitLog: Encodable, Sendable {
        let repository: String
        let commits: [GitCommit]
        let nextCursor: String?
    }

    struct GitShow: Encodable, Sendable {
        let repository: String
        let commit: GitCommit
        let path: String?
        let content: String?
        let size: Int?
    }

    struct GitDiff: Encodable, Sendable {
        let repository: String
        let fromCommitHash: String?
        let toCommitHash: String?
        let workingTree: Bool
        let files: [GitDiffFile]
        let patch: String
        let truncated: Bool
    }

    struct GitDiffFile: Encodable, Sendable {
        let path: String
        let previousPath: String?
        let change: String
        let additions: Int
        let deletions: Int
        let binary: Bool
        let patchIncluded: Bool
    }

    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Package: Codable {
        struct Service: Codable {
            let id: ServiceID

            init(id: ServiceID) {
                self.id = id
            }

            init(from decoder: Decoder) throws {
                id = try ServiceID(from: decoder)
            }

            func encode(to encoder: Encoder) throws {
                try id.encode(to: encoder)
            }
        }

        let version: Int
        let name: String
        let contentHash: String?
        var services: [Service]
    }

    private struct ServiceID: Codable, Hashable {
        let rawValue: String
        let kind: ServiceKind
        let identity: String

        var runtimeID: String { kind == .iOS ? rawValue : identity }
        var path: String { "\(kind.rawValue)/\(identity)" }

        init(_ rawValue: String) throws {
            guard rawValue.count <= 253,
                  rawValue.range(
                    of: "^(?:web|ios|mcp):[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$",
                    options: .regularExpression
                  ) != nil,
                  let separator = rawValue.firstIndex(of: ":"),
                  let kind = ServiceKind(rawValue: String(rawValue[..<separator]))
            else { throw Failure(message: "Invalid service identity") }
            self.rawValue = rawValue
            self.kind = kind
            identity = String(rawValue[rawValue.index(after: separator)...])
        }

        init(kind: ServiceKind, runtimeID: String) throws {
            try self.init(kind == .iOS && runtimeID.hasPrefix("ios:") ? runtimeID : "\(kind.rawValue):\(runtimeID)")
        }

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            do {
                try self.init(value)
            } catch {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: error.localizedDescription
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    struct InstalledRepository: Codable {
        let id: String
        var origin: URL
        var isEnabled: Bool
    }

    struct Configuration: Codable {
        var formatVersion = 1
        var bundledEnabled = true
        var developmentEnabled = true
        var repositories: [InstalledRepository] = []
        var resolutions: [String: String] = [:]

        init(
            formatVersion: Int = 1,
            bundledEnabled: Bool = true,
            developmentEnabled: Bool = true,
            repositories: [InstalledRepository] = [],
            resolutions: [String: String] = [:]
        ) {
            self.formatVersion = formatVersion
            self.bundledEnabled = bundledEnabled
            self.developmentEnabled = developmentEnabled
            self.repositories = repositories
            self.resolutions = resolutions
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            bundledEnabled = try values.decodeIfPresent(Bool.self, forKey: .bundledEnabled) ?? true
            developmentEnabled = try values.decodeIfPresent(Bool.self, forKey: .developmentEnabled) ?? true
            repositories = try values.decodeIfPresent([InstalledRepository].self, forKey: .repositories) ?? []
            resolutions = try values.decodeIfPresent([String: String].self, forKey: .resolutions) ?? [:]
        }
    }

    private struct LoadedRepository {
        let descriptor: Repository
        let root: URL
        let package: Package
    }

    private struct Candidate {
        let repository: LoadedRepository
        let service: Package.Service
    }

    private struct ActiveSource {
        let kind: ServiceKind
        let root: URL
        let repositoryID: String
        let provenance: Repository.Provenance
    }

    static let bundledID = "bundled"
    static let localID = "local"

    private let bundledRoot: URL?
    private let developmentRemote: URL?
    private let repositoriesRoot: URL
    private let configurationURL: URL
    private var configuration: Configuration
    private var activeSources: [String: ActiveSource] = [:]

    init(root: URL? = nil, developmentRemote: URL? = nil) {
        bundledRoot = root ?? Bundle.main.url(forResource: "OxServices", withExtension: "bundle")
        self.developmentRemote = developmentRemote
        repositoriesRoot = AppStoragePaths.serviceRepositories
        configurationURL = AppStoragePaths.serviceRepositoriesConfiguration
        configuration = Self.loadConfiguration(from: configurationURL)
    }

    func monoRepository() async throws -> MonoRepository {
        var localMaterializationFailure: String?
        do {
            try materializeLocalRepository()
        } catch {
            let message = Self.errorMessage(error)
            localMaterializationFailure = message
            Log.service.error("ServiceRepository.local unavailable error=\(message)")
        }
        let bundled = loadBundledRepository()
        let development = loadDevelopmentRepository()
        let local = localMaterializationFailure.map(failedLocal) ?? loadLocalRepository()
        let installed = configuration.repositories.map(loadInstalledRepository)
        let available = [bundled, development, local].compactMap { $0 } + installed
        let loaded = available.compactMap { loaded in
            if case .ready = loaded.descriptor.state { return loaded }
            return nil
        }
        let descriptors = available.map(\.descriptor)
        var candidates: [String: [Candidate]] = [:]
        for repository in loaded where repository.descriptor.isEnabled {
            for service in repository.package.services {
                candidates[service.id.runtimeID, default: []].append(Candidate(repository: repository, service: service))
            }
        }

        var selected: [Candidate] = []
        var conflicts: [Conflict] = []
        for serviceID in candidates.keys.sorted() {
            let options = candidates[serviceID]!.sorted {
                if $0.repository.descriptor.provenance != $1.repository.descriptor.provenance {
                    return $0.repository.descriptor.provenance.selectionPriority
                        < $1.repository.descriptor.provenance.selectionPriority
                }
                return $0.repository.descriptor.name.localizedCaseInsensitiveCompare($1.repository.descriptor.name) == .orderedAscending
            }
            if options.count == 1 {
                selected.append(options[0])
                continue
            }
            let saved = configuration.resolutions[serviceID]
            let chosen = options.first { $0.repository.descriptor.id == saved }
                ?? options.first { $0.repository.descriptor.provenance == .bundled }
            if let chosen { selected.append(chosen) }
            conflicts.append(Conflict(
                id: serviceID,
                serviceID: serviceID,
                candidates: options.map {
                    Conflict.Candidate(
                        id: "\(serviceID):\($0.repository.descriptor.id)",
                        repositoryID: $0.repository.descriptor.id,
                        repositoryName: $0.repository.descriptor.name
                    )
                },
                selectedRepositoryID: chosen?.repository.descriptor.id
            ))
        }

        activeSources = [:]
        var web: [ManifestFile] = []
        var iOS: [RepositoryManifestFile] = []
        var mcp: [RepositoryManifestFile] = []
        for candidate in selected {
            let repository = candidate.repository
            let service = candidate.service
            let serviceRoot = repository.root.appendingPathComponent(service.id.path, isDirectory: true)
            guard let data = try? Data(contentsOf: serviceRoot.appendingPathComponent("service.json")) else { continue }
            activeSources[service.id.runtimeID] = ActiveSource(
                kind: service.id.kind,
                root: serviceRoot,
                repositoryID: repository.descriptor.id,
                provenance: repository.descriptor.provenance
            )
            switch service.id.kind {
            case .web:
                web.append(ManifestFile(
                    repositoryID: repository.descriptor.id,
                    provenance: repository.descriptor.provenance,
                    domain: service.id.runtimeID,
                    data: data
                ))
            case .iOS:
                iOS.append(RepositoryManifestFile(
                    repositoryID: repository.descriptor.id,
                    provenance: repository.descriptor.provenance,
                    id: service.id.runtimeID,
                    data: data
                ))
            case .mcp:
                mcp.append(RepositoryManifestFile(
                    repositoryID: repository.descriptor.id,
                    provenance: repository.descriptor.provenance,
                    id: service.id.runtimeID,
                    data: data
                ))
            }
        }
        let input = selected.map {
            let repository = $0.repository
            let version: String?
            switch repository.descriptor.provenance {
            case .local:
                version = try? Self.contentHash(at: repository.root, package: repository.package)
            case .bundled, .development, .remote:
                version = repository.package.contentHash
                    ?? (try? Self.contentHash(at: repository.root, package: repository.package))
            }
            return "\($0.service.id.rawValue):\(repository.descriptor.id):\(version ?? "unknown")"
        }.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        Log.service.info("ServiceRepository.monoRepository repositories=\(descriptors.count) enabled=\(descriptors.count(where: \.isEnabled)) services=\(selected.count) conflicts=\(conflicts.count) hash=\(hash.prefix(12))")
        return MonoRepository(
            repositories: descriptors,
            conflicts: conflicts,
            webManifests: web,
            iOSManifests: iOS,
            mcpManifests: mcp,
            hash: hash
        )
    }

    func source(domain: String, skills: [String]) async -> Source? {
        guard let root = activeSources[domain]?.root,
              let actions = try? String(contentsOf: root.appendingPathComponent("actions.js"), encoding: .utf8)
        else { return nil }
        var bodies: [String: String] = [:]
        for skill in skills {
            guard let body = try? String(
                contentsOf: root.appendingPathComponent("skills/\(skill)/SKILL.md"),
                encoding: .utf8
            ) else { return nil }
            bodies[skill] = body
        }
        return Source(actions: actions, skills: bodies)
    }

    func setEnabled(repositoryID: String, enabled: Bool) throws {
        if repositoryID == Self.bundledID {
            configuration.bundledEnabled = enabled
        } else if repositoryID == Self.localID {
            throw Failure(message: "Local is always enabled.")
        } else if repositoryID == "development", developmentRemote != nil {
            configuration.developmentEnabled = enabled
        } else if let index = configuration.repositories.firstIndex(where: { $0.id == repositoryID }) {
            configuration.repositories[index].isEnabled = enabled
        } else {
            throw Failure(message: "Repository not found")
        }
        try saveConfiguration()
        Log.service.info("ServiceRepository.enabled id=\(repositoryID) enabled=\(enabled)")
    }

    func setResolution(serviceID: String, repositoryID: String) throws {
        configuration.resolutions[serviceID] = repositoryID
        try saveConfiguration()
        Log.service.info("ServiceRepository.resolution service=\(serviceID) repository=\(repositoryID)")
    }

    func install(from origin: URL) async throws {
        try Self.validateOrigin(origin)
        guard !configuration.repositories.contains(where: { $0.origin == origin }) else {
            throw Failure(message: "Repository is already installed")
        }
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: repositoriesRoot, withIntermediateDirectories: true)
        let staging = repositoriesRoot.appendingPathComponent(".installing-\(id)", isDirectory: true)
        let destination = repositoryDirectory(id)
        do {
            Log.service.info("ServiceRepository.install origin=\(Self.redacted(origin)) id=\(id)")
            try await replaceSnapshot(from: origin, at: destination, staging: staging, provenance: .remote)
            configuration.repositories.append(InstalledRepository(id: id, origin: origin, isEnabled: true))
            try saveConfiguration()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure(message: Self.errorMessage(error))
        }
    }

    func update(repositoryID: String) async throws {
        if repositoryID == "development", let developmentRemote {
            Log.service.info("ServiceRepository.update origin=\(Self.redacted(developmentRemote)) id=development")
            try await syncDevelopmentRepository()
            return
        }
        guard let stored = configuration.repositories.first(where: { $0.id == repositoryID }) else {
            throw Failure(message: "Repository not found")
        }
        let destination = repositoryDirectory(repositoryID)
        let staging = repositoriesRoot.appendingPathComponent(".updating-\(repositoryID)", isDirectory: true)
        do {
            Log.service.info("ServiceRepository.update origin=\(Self.redacted(stored.origin)) id=\(repositoryID)")
            try await replaceSnapshot(from: stored.origin, at: destination, staging: staging, provenance: .remote)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure(message: Self.errorMessage(error))
        }
    }

    func remove(repositoryID: String) throws {
        guard repositoryID != Self.bundledID,
              repositoryID != Self.localID,
              let index = configuration.repositories.firstIndex(where: { $0.id == repositoryID })
        else { throw Failure(message: "Repository not found") }
        try? FileManager.default.removeItem(at: repositoryDirectory(repositoryID))
        configuration.repositories.remove(at: index)
        configuration.resolutions = configuration.resolutions.filter { $0.value != repositoryID }
        try saveConfiguration()
        Log.service.info("ServiceRepository.remove id=\(repositoryID)")
    }

    func createService(kind: ServiceKind, id: String) throws {
        guard kind == .web else {
            throw Failure(message: "Only Local web services can be created.")
        }
        try createWebService(domain: id)
    }

    private func createWebService(domain: String) throws {
        guard Self.isServiceID(domain), domain.contains(".") else {
            throw Failure(message: "Use a lowercase website domain for the Local service.")
        }
        _ = try editableLocalRepository()
        var package = try Self.loadPackage(at: localRoot, provenance: .local)
        guard !package.services.contains(where: { $0.id.runtimeID == domain }) else {
            throw Failure(message: "A Local service already exists for \(domain).")
        }
        let service = Package.Service(id: try ServiceID(kind: .web, runtimeID: domain))
        let serviceRoot = localRoot.appendingPathComponent(service.id.path, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: serviceRoot.path) else {
            throw Failure(message: "Local source already exists for \(domain).")
        }
        do {
            try FileManager.default.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "domain": domain,
                "name": domain,
                "description": "Local service for \(domain).",
                "baseUrl": "https://\(domain)/",
                "actions": [],
            ]
            var manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            manifestData.append(0x0A)
            try manifestData.write(to: serviceRoot.appendingPathComponent("service.json"), options: .atomic)
            try Data("window.ox.install(1, () => {});\n".utf8)
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
        Log.service.info("ServiceRepository.local create domain=\(domain)")
    }

    func copyServiceToLocal(id: String) throws {
        guard let source = activeSources[id] else { throw Failure(message: "Service not found") }
        guard source.provenance != .local else { return }
        guard source.kind != .iOS else { throw Failure(message: "Native iOS services cannot be copied to Local.") }
        _ = try editableLocalRepository()
        var package = try Self.loadPackage(at: localRoot, provenance: .local)
        guard !package.services.contains(where: { $0.id.runtimeID == id }) else {
            throw Failure(message: "A Local service already exists for \(id).")
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
        Log.service.info("ServiceRepository.local copy id=\(id) source=\(source.repositoryID)")
    }

    func deleteLocalService(id: String) throws -> ServiceKind {
        _ = try editableLocalRepository()
        let originalPackage = try Self.loadPackage(at: localRoot, provenance: .local)
        guard let index = originalPackage.services.firstIndex(where: { $0.id.runtimeID == id }) else {
            throw Failure(message: "No Local service exists for \(id).")
        }
        let service = originalPackage.services[index]
        let serviceRoot = localRoot.appendingPathComponent(service.id.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: serviceRoot.path) else {
            throw Failure(message: "Local source does not exist for \(id).")
        }
        let staging = repositoriesRoot.appendingPathComponent(".deleting-\(UUID().uuidString)", isDirectory: true)
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
            configuration = originalConfiguration
            try? saveConfiguration()
            try? Self.writePackage(originalPackage, at: localRoot)
            if FileManager.default.fileExists(atPath: staging.path) {
                try? FileManager.default.moveItem(at: staging, to: serviceRoot)
            }
            throw error
        }
        Log.service.info("ServiceRepository.local delete id=\(id) kind=\(service.id.kind.rawValue)")
        return service.id.kind
    }

    func listSource(kind: ServiceKind, id: String, path: [String]) throws -> [Entry] {
        let source = try activeSource(kind: kind, id: id)
        if source.provenance != .local {
            guard path.isEmpty else { throw Failure(message: "Only Local service source is available beyond service.json.") }
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

    func sourceIsDirectory(kind: ServiceKind, id: String, path: [String]) throws -> Bool {
        let source = try activeSource(kind: kind, id: id)
        guard source.provenance == .local || path.isEmpty else { return false }
        return try sourceURL(source, path: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    func readSource(kind: ServiceKind, id: String, path: [String]) throws -> Data {
        let source = try activeSource(kind: kind, id: id)
        guard source.provenance == .local || path == ["service.json"] else {
            throw Failure(message: "Only Local service source is available beyond service.json.")
        }
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
        let existed = FileManager.default.fileExists(atPath: url.path)
        let previous = existed ? try Data(contentsOf: url) : nil
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            _ = try Self.loadPackage(at: localRoot, provenance: .local)
        } catch {
            if let previous { try? previous.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        Log.service.info("ServiceRepository.local write id=\(id) path=\(path.joined(separator: "/")) bytes=\(data.count)")
    }

    func deleteLocalSource(kind: ServiceKind, id: String, path: [String]) throws {
        let source = try editableSource(kind: kind, id: id)
        let url = try sourceURL(source, path: path)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure(message: "Only Local service files can be deleted.")
        }
        let previous = try Data(contentsOf: url)
        do {
            try FileManager.default.removeItem(at: url)
            _ = try Self.loadPackage(at: localRoot, provenance: .local)
        } catch {
            try? previous.write(to: url, options: .atomic)
            throw error
        }
        Log.service.info("ServiceRepository.local delete id=\(id) path=\(path.joined(separator: "/"))")
    }

    func sourcePaths(kind: ServiceKind, id: String) throws -> [String] {
        let source = try activeSource(kind: kind, id: id)
        if source.provenance != .local { return ["services/\(kind.rawValue)/\(id)/service.json"] }
        guard let enumerator = FileManager.default.enumerator(
            at: source.root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            var relative = url.path.replacingOccurrences(of: source.root.path + "/", with: "", options: [.anchored])
            if relative == "manifest.json" {
                if FileManager.default.fileExists(atPath: source.root.appendingPathComponent("service.json").path) { continue }
                relative = "service.json"
            }
            paths.append("services/\(kind.rawValue)/\(id)/\(relative)")
            if paths.count >= VirtualFileSystem.maximumSearchFiles { break }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func gitStatus(repositoryID: String) throws -> GitStatus {
        let loaded = try gitRepository(repositoryID)
        return try Self.gitStatus(repositoryID: repositoryID, provenance: loaded.descriptor.provenance, root: loaded.root)
    }

    func gitLog(repositoryID: String, limit: Int, cursor: String?) throws -> GitLog {
        let loaded = try gitRepository(repositoryID)
        let repository = try SwiftGitX.Repository.open(at: loaded.root)
        let tip = try Self.tipCommit(in: repository)
        var commits: [GitCommit] = []
        var include = cursor == nil
        var foundCursor = cursor == nil
        var hasMore = false
        for commit in repository.log(from: tip, sorting: .time) {
            if !include {
                if commit.id.hex == cursor {
                    include = true
                    foundCursor = true
                }
                continue
            }
            if commits.count == limit {
                hasMore = true
                break
            }
            commits.append(try Self.gitCommit(commit))
        }
        guard foundCursor else { throw Failure(message: "Git log cursor is not in the repository history") }
        return GitLog(
            repository: repositoryID,
            commits: commits,
            nextCursor: hasMore ? commits.last?.commitHash : nil
        )
    }

    func gitShow(repositoryID: String, commitHash: String, path: String?) throws -> GitShow {
        let loaded = try gitRepository(repositoryID)
        let repository = try SwiftGitX.Repository.open(at: loaded.root)
        let commit = try Self.historyCommit(commitHash, in: repository)
        guard let path else {
            return GitShow(
                repository: repositoryID,
                commit: try Self.gitCommit(commit),
                path: nil,
                content: nil,
                size: nil
            )
        }
        let normalized = try Self.gitPath(path)
        let blob = try Self.blob(at: normalized, commit: commit, repository: repository)
        guard blob.content.count <= 1_000_000 else { throw Failure(message: "Historical file is too large to show") }
        guard let content = String(data: blob.content, encoding: .utf8) else {
            throw Failure(message: "Historical file is not UTF-8 text")
        }
        return GitShow(
            repository: repositoryID,
            commit: try Self.gitCommit(commit),
            path: normalized,
            content: content,
            size: blob.content.count
        )
    }

    func gitDiff(
        repositoryID: String,
        commitHash: String?,
        baseCommitHash: String?,
        path: String?
    ) throws -> GitDiff {
        guard commitHash != nil || baseCommitHash == nil else {
            throw Failure(message: "commitHash is required when baseCommitHash is provided")
        }
        let loaded = try gitRepository(repositoryID)
        let repository = try SwiftGitX.Repository.open(at: loaded.root)
        let path = try path.map(Self.gitPath)
        if let commitHash {
            let commit = try Self.historyCommit(commitHash, in: repository)
            if let baseCommitHash {
                let base = try Self.historyCommit(baseCommitHash, in: repository)
                return try Self.gitDiff(
                    repositoryID: repositoryID,
                    fromCommitHash: base.id.hex,
                    toCommitHash: commit.id.hex,
                    workingTree: false,
                    diff: repository.diff(from: base, to: commit),
                    repository: repository,
                    root: loaded.root,
                    path: path
                )
            }
            if let parent = try commit.parents.first {
                return try Self.gitDiff(
                    repositoryID: repositoryID,
                    fromCommitHash: parent.id.hex,
                    toCommitHash: commit.id.hex,
                    workingTree: false,
                    diff: repository.diff(from: parent, to: commit),
                    repository: repository,
                    root: loaded.root,
                    path: path
                )
            }
            return try Self.gitRootDiff(
                repositoryID: repositoryID,
                commit: commit,
                repository: repository,
                path: path
            )
        }
        guard let head = try repository.HEAD.target as? Commit else {
            throw Failure(message: "Repository HEAD is not a commit")
        }
        return try Self.gitDiff(
            repositoryID: repositoryID,
            fromCommitHash: head.id.hex,
            toCommitHash: nil,
            workingTree: true,
            diff: repository.diff(to: [.workingTree, .index]),
            repository: repository,
            root: loaded.root,
            path: path
        )
    }

    func gitCheckout(repositoryID: String, commitHash: String) throws -> GitStatus {
        let loaded = try gitRepository(repositoryID)
        let repository = try SwiftGitX.Repository.open(at: loaded.root)
        guard try repository.status().isEmpty else {
            throw Failure(message: "Restore or save current changes before viewing service history")
        }
        guard let previous = try repository.HEAD.target as? Commit else {
            throw Failure(message: "Repository HEAD is not a commit")
        }
        let wasHistorical = repository.isHEADDetached
        do {
            if commitHash == "latest" {
                let main = try repository.branch.get(named: "main", type: .local)
                try repository.switch(to: main)
            } else {
                let commit = try Self.historyCommit(commitHash, in: repository)
                let tip = try Self.tipCommit(in: repository)
                if commit.id == tip.id {
                    let main = try repository.branch.get(named: "main", type: .local)
                    try repository.switch(to: main)
                } else {
                    try repository.switch(to: commit)
                }
            }
            _ = try Self.loadPackage(at: loaded.root, provenance: loaded.descriptor.provenance)
        } catch {
            if wasHistorical {
                try? repository.switch(to: previous)
            } else if let main = repository.branch["main", type: .local] {
                try? repository.switch(to: main)
            }
            throw error
        }
        let status = try Self.gitStatus(repositoryID: repositoryID, provenance: loaded.descriptor.provenance, root: loaded.root)
        Log.service.info("ServiceRepository.git checkout repository=\(repositoryID) commit=\(status.commitHash.prefix(12)) view=\(status.view)")
        return status
    }

    func gitCommitLocal(message: String) throws -> GitCommit {
        let repository = try editableLocalRepository()
        let before = try repository.status()
        guard !before.isEmpty else { throw Failure(message: "Local has no changes to save") }
        try Self.stageAllChanges(in: repository)
        let commit = try repository.commit(message: message)
        Log.service.info("ServiceRepository.git commit repository=local commit=\(commit.id.abbreviated) files=\(before.count)")
        return try Self.gitCommit(commit)
    }

    func prepareLocalRevert(commitHash: String) throws {
        let repository = try editableLocalRepository()
        guard try repository.status().isEmpty else {
            throw Failure(message: "Restore or save Local changes before undoing a saved version")
        }
        let commit = try Self.historyCommit(commitHash, in: repository)
        guard !(try commit.parents).isEmpty else { throw Failure(message: "The initial Local version cannot be undone") }
        do {
            try repository.revert(commit)
            let status = try repository.status()
            guard !status.contains(where: { $0.status.contains(.conflicted) }) else {
                throw Failure(message: "Undoing this version conflicts with later Local changes")
            }
            _ = try Self.loadPackage(at: localRoot, provenance: .local)
        } catch {
            try? Self.restoreAll(in: repository)
            throw error
        }
    }

    func commitPreparedLocalRevert(message: String) throws -> GitCommit {
        let repository = try editableLocalRepository()
        let commit = try repository.commit(message: message)
        Log.service.info("ServiceRepository.git revert repository=local commit=\(commit.id.abbreviated)")
        return try Self.gitCommit(commit)
    }

    func abortPreparedLocalMutation() {
        guard let repository = try? SwiftGitX.Repository.open(at: localRoot) else { return }
        try? Self.restoreAll(in: repository)
    }

    func gitRestoreLocal(path: String?) throws -> GitStatus {
        let repository = try editableLocalRepository()
        if let path {
            try Self.restore(path: path, in: repository)
        } else {
            try Self.restoreAll(in: repository)
        }
        _ = try Self.loadPackage(at: localRoot, provenance: .local)
        Log.service.info("ServiceRepository.git restore repository=local path=\(path ?? "all")")
        return try Self.gitStatus(repositoryID: Self.localID, provenance: .local, root: localRoot)
    }

    private func gitRepository(_ id: String) throws -> LoadedRepository {
        guard id == Self.localID else {
            throw Failure(message: "Only Local services have Git history")
        }
        try materializeLocalRepository()
        let loaded = loadLocalRepository()
        guard case .ready = loaded.descriptor.state else {
            throw Failure(message: "Service repository is unavailable")
        }
        return loaded
    }

    private func editableLocalRepository() throws -> SwiftGitX.Repository {
        try materializeLocalRepository()
        let repository = try SwiftGitX.Repository.open(at: localRoot)
        guard !repository.isHEADDetached else {
            throw Failure(message: "Local is viewing a saved version; return to latest before editing history")
        }
        return repository
    }

    private var localRoot: URL {
        repositoryDirectory(Self.localID)
    }

    private var localRepositorySeed: URL? {
        bundledRoot?
            .appendingPathComponent("Repositories.bundle", isDirectory: true)
            .appendingPathComponent("Local.git", isDirectory: true)
    }

    private func materializeLocalRepository() throws {
        let packageURL = Self.repositoryManifestURL(at: localRoot)
        if !FileManager.default.fileExists(atPath: packageURL.path) {
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
            try Self.writePackage(
                Package(version: 1, name: "Local", contentHash: nil, services: []),
                at: localRoot
            )
            Log.service.info("ServiceRepository.local materialized")
        }
        try ProfileMigrator.migrateLegacyLocalServiceRepository(at: localRoot, seed: localRepositorySeed)
        try installLocalRepositoryMetadata()
        try ProfileMigrator.migrateLegacyLocalServiceActions(at: localRoot)
    }

    private func loadLocalRepository() -> LoadedRepository {
        do {
            let package = try Self.loadPackage(at: localRoot, provenance: .local)
            let git = try Self.gitState(at: localRoot)
            return LoadedRepository(
                descriptor: Repository(
                    id: Self.localID,
                    name: package.name,
                    origin: nil,
                    commitHash: git.commitHash,
                    tipCommitHash: git.tipCommitHash,
                    view: git.view,
                    lastSyncedAt: nil,
                    isEnabled: true,
                    provenance: .local,
                    serviceCount: package.services.count,
                    services: Self.serviceReferences(in: package),
                    state: .ready
                ),
                root: localRoot,
                package: package
            )
        } catch {
            return LoadedRepository(
                descriptor: Repository(
                    id: Self.localID,
                    name: "Local",
                    origin: nil,
                    commitHash: nil,
                    tipCommitHash: nil,
                    view: .live,
                    lastSyncedAt: nil,
                    isEnabled: true,
                    provenance: .local,
                    serviceCount: 0,
                    services: [],
                    state: .failed(Self.errorMessage(error))
                ),
                root: localRoot,
                package: Package(version: 1, name: "Local", contentHash: nil, services: [])
            )
        }
    }

    private func failedLocal(_ message: String) -> LoadedRepository {
        LoadedRepository(
            descriptor: Repository(
                id: Self.localID,
                name: "Local",
                origin: nil,
                commitHash: nil,
                tipCommitHash: nil,
                view: .live,
                lastSyncedAt: nil,
                isEnabled: true,
                provenance: .local,
                serviceCount: 0,
                services: [],
                state: .failed(message)
            ),
            root: localRoot,
            package: Package(version: 1, name: "Local", contentHash: nil, services: [])
        )
    }

    private func activeSource(kind: ServiceKind, id: String) throws -> ActiveSource {
        guard let source = activeSources[id], source.kind == kind else { throw Failure(message: "Service not found") }
        return source
    }

    private func editableSource(kind: ServiceKind, id: String) throws -> ActiveSource {
        let source = try activeSource(kind: kind, id: id)
        guard source.provenance == .local else {
            throw Failure(message: "Only Local services are editable. Copy this service to Local before editing it.")
        }
        _ = try editableLocalRepository()
        return source
    }

    private func sourceURL(_ source: ActiveSource, path: [String], legacyFallback: Bool = false) throws -> URL {
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
        return url
    }

    private static func writePackage(_ package: Package, at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(package)
        data.append(0x0A)
        try data.write(to: root.appendingPathComponent("repository.json"), options: .atomic)
    }

    private static func contentHash(at root: URL, package: Package) throws -> String {
        var digest = SHA256()
        for service in package.services.sorted(by: { $0.id.path < $1.id.path }) {
            let serviceRoot = root.appendingPathComponent(service.id.path, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: serviceRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var files: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink != true, values.isRegularFile == true { files.append(url) }
            }
            for url in files.sorted(by: { $0.path < $1.path }) {
                digest.update(data: Data(url.path.replacingOccurrences(of: root.path + "/", with: "").utf8))
                digest.update(data: try Data(contentsOf: url))
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isServiceID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9]+(?:[.:-][a-z0-9]+)*$", options: .regularExpression) != nil
    }

    private func loadBundledRepository() -> LoadedRepository {
        guard let bundledRoot else {
            return failedBundled("OxServices.bundle is missing")
        }
        do {
            let package = try Self.loadPackage(at: bundledRoot, provenance: .bundled)
            return LoadedRepository(
                descriptor: Repository(
                    id: Self.bundledID,
                    name: package.name,
                    origin: nil,
                    commitHash: nil,
                    tipCommitHash: nil,
                    view: .live,
                    lastSyncedAt: nil,
                    isEnabled: configuration.bundledEnabled,
                    provenance: .bundled,
                    serviceCount: package.services.count,
                    services: Self.serviceReferences(in: package),
                    state: .ready
                ),
                root: bundledRoot,
                package: package
            )
        } catch {
            return failedBundled(Self.errorMessage(error))
        }
    }

    private func failedBundled(_ message: String) -> LoadedRepository {
        LoadedRepository(
            descriptor: Repository(
                id: Self.bundledID,
                name: "Built-in",
                origin: nil,
                commitHash: nil,
                tipCommitHash: nil,
                view: .live,
                lastSyncedAt: nil,
                isEnabled: configuration.bundledEnabled,
                provenance: .bundled,
                serviceCount: 0,
                services: [],
                state: .failed(message)
            ),
            root: bundledRoot ?? Bundle.main.bundleURL,
            package: Package(version: 1, name: "Built-in", contentHash: nil, services: [])
        )
    }

    private func loadDevelopmentRepository() -> LoadedRepository? {
        guard let developmentRemote else { return nil }
        let root = AppStoragePaths.developmentServiceSnapshot
        do {
            let package = try Self.loadPackage(at: root, provenance: .development)
            return LoadedRepository(
                descriptor: Repository(
                    id: "development",
                    name: package.name,
                    origin: developmentRemote,
                    commitHash: nil,
                    tipCommitHash: nil,
                    view: .live,
                    lastSyncedAt: Self.snapshotDate(at: root),
                    isEnabled: configuration.developmentEnabled,
                    provenance: .development,
                    serviceCount: package.services.count,
                    services: Self.serviceReferences(in: package),
                    state: .ready
                ),
                root: root,
                package: package
            )
        } catch {
            return LoadedRepository(
                descriptor: Repository(
                    id: "development",
                    name: "Development Server",
                    origin: developmentRemote,
                    commitHash: nil,
                    tipCommitHash: nil,
                    view: .live,
                    lastSyncedAt: Self.snapshotDate(at: root),
                    isEnabled: configuration.developmentEnabled,
                    provenance: .development,
                    serviceCount: 0,
                    services: [],
                    state: .failed(error.localizedDescription)
                ),
                root: root,
                package: Package(version: 1, name: "Development Server", contentHash: nil, services: [])
            )
        }
    }

    private func loadInstalledRepository(_ stored: InstalledRepository) -> LoadedRepository {
        let root = repositoryDirectory(stored.id)
        do {
            let package = try Self.loadPackage(at: root, provenance: .remote)
            return LoadedRepository(
                descriptor: Repository(
                    id: stored.id,
                    name: package.name,
                    origin: stored.origin,
                    commitHash: nil,
                    tipCommitHash: nil,
                    view: .live,
                    lastSyncedAt: Self.snapshotDate(at: root),
                    isEnabled: stored.isEnabled,
                    provenance: .remote,
                    serviceCount: package.services.count,
                    services: Self.serviceReferences(in: package),
                    state: .ready
                ),
                root: root,
                package: package
            )
        } catch {
            return LoadedRepository(
                descriptor: Repository(
                    id: stored.id,
                    name: stored.origin.host ?? "Repository",
                    origin: stored.origin,
                    commitHash: nil,
                    tipCommitHash: nil,
                    view: .live,
                    lastSyncedAt: Self.snapshotDate(at: root),
                    isEnabled: stored.isEnabled,
                    provenance: .remote,
                    serviceCount: 0,
                    services: [],
                    state: .failed(error.localizedDescription)
                ),
                root: root,
                package: Package(version: 1, name: "Invalid", contentHash: nil, services: [])
            )
        }
    }

    private static func loadPackage(at root: URL, provenance: Repository.Provenance) throws -> Package {
        let packageURL = repositoryManifestURL(at: root)
        let values = try packageURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 512_000 else {
            throw Failure(message: "repository.json is invalid or too large")
        }
        let data = try Data(contentsOf: packageURL)
        try validatePackageShape(data)
        guard let package = try? JSONDecoder().decode(Package.self, from: data) else {
            throw Failure(message: "repository.json is invalid")
        }
        guard package.version == 1 else { throw Failure(message: "Unsupported repository.json version") }
        guard !package.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              package.name.count <= 100,
              package.services.count <= 256 else {
            throw Failure(message: "repository.json metadata is invalid")
        }
        if let hash = package.contentHash,
           hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil {
            throw Failure(message: "repository.json content hash is invalid")
        }
        var identities = Set<String>()
        for service in package.services {
            guard provenance == .bundled || service.id.kind != .iOS else {
                throw Failure(message: "External repositories cannot provide native iOS services")
            }
            guard identities.insert(service.id.runtimeID).inserted else {
                throw Failure(message: "Invalid or duplicate service \(service.id.rawValue)")
            }
            try validateService(service, root: root)
        }
        return package
    }

    private static func serviceReferences(in package: Package) -> [ServiceReference] {
        package.services
            .map { ServiceReference(id: $0.id.rawValue, runtimeID: $0.id.runtimeID) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func validateService(_ service: Package.Service, root: URL) throws {
        let serviceRoot = root.appendingPathComponent(service.id.path, isDirectory: true)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedServiceRoot = serviceRoot.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedServiceRoot.path.hasPrefix(resolvedRoot.path + "/") else {
            throw Failure(message: "Service path escapes the repository")
        }
        let manifestURL = serviceManifestURL(at: serviceRoot)
        try validateRegularFile(manifestURL, maximumSize: 512_000)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        let manifestID = service.id.kind == .mcp ? object?["id"] as? String : object?["domain"] as? String
        guard manifestID == service.id.runtimeID else {
            throw Failure(message: "Manifest identity mismatch for \(service.id.rawValue)")
        }
        if service.id.kind == .web {
            try validateRegularFile(serviceRoot.appendingPathComponent("actions.js"), maximumSize: 1_000_000)
        }
        let enumerator = FileManager.default.enumerator(
            at: serviceRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var total = 0
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw Failure(message: "Symbolic links are not supported") }
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
            guard total <= 4_000_000 else { throw Failure(message: "Service \(service.id.rawValue) is too large") }
        }
    }

    private static func validatePackageShape(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "name", "contentHash", "services"]),
              object["services"] is [String]
        else { throw Failure(message: "repository.json is invalid") }
    }

    private static func validateRegularFile(_ url: URL, maximumSize: Int) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumSize else {
            throw Failure(message: "Invalid file \(url.lastPathComponent)")
        }
    }

    private static func repositoryManifestURL(at root: URL) -> URL {
        let current = root.appendingPathComponent("repository.json")
        if FileManager.default.fileExists(atPath: current.path) { return current }
        return root.appendingPathComponent("ox.json")
    }

    private static func serviceManifestURL(at root: URL) -> URL {
        let current = root.appendingPathComponent("service.json")
        if FileManager.default.fileExists(atPath: current.path) { return current }
        return root.appendingPathComponent("manifest.json")
    }

    private func syncDevelopmentRepository() async throws {
        guard let developmentRemote else { return }
        let root = AppStoragePaths.developmentServiceSnapshot
        let staging = root.deletingLastPathComponent().appendingPathComponent(".updating-development", isDirectory: true)
        do {
            try await replaceSnapshot(from: developmentRemote, at: root, staging: staging, provenance: .development)
        } catch {
            throw Failure(message: Self.errorMessage(error))
        }
    }

    private func replaceSnapshot(
        from origin: URL,
        at destination: URL,
        staging: URL,
        provenance: Repository.Provenance
    ) async throws {
        let manager = FileManager.default
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".snapshot-backup-\(UUID().uuidString)", isDirectory: true)
        try? manager.removeItem(at: staging)
        var movedExisting = false
        do {
            let repository = try await SwiftGitX.Repository.clone(from: origin, to: staging)
            guard let head = try repository.HEAD.target as? Commit else {
                throw Failure(message: "Repository HEAD is not a commit")
            }
            _ = try Self.loadPackage(at: staging, provenance: provenance)
            try manager.removeItem(at: staging.appendingPathComponent(".git", isDirectory: true))
            if manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: destination, to: backup)
                movedExisting = true
            }
            do {
                try manager.moveItem(at: staging, to: destination)
            } catch {
                if movedExisting {
                    do {
                        try manager.moveItem(at: backup, to: destination)
                    } catch let rollbackError {
                        throw Failure(message: "Repository snapshot publication failed and rollback failed: \(rollbackError.localizedDescription)")
                    }
                }
                throw error
            }
            try? AppStoragePaths.excludeFromBackup(destination)
            if movedExisting {
                do {
                    try manager.removeItem(at: backup)
                } catch {
                    Log.service.warning("ServiceRepository.snapshot backup cleanup failed error=\(error.localizedDescription)")
                }
            }
            Log.service.info("ServiceRepository.snapshot installed provenance=\(provenance.rawValue) head=\(head.id.abbreviated)")
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private func repositoryDirectory(_ id: String) -> URL {
        repositoriesRoot.appendingPathComponent(id, isDirectory: true)
    }

    private func saveConfiguration() throws {
        try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        try data.write(to: configurationURL, options: .atomic)
    }

    private static func loadConfiguration(from url: URL) -> Configuration {
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              configuration.formatVersion == 1 else { return Configuration() }
        return configuration
    }

    private static func validateOrigin(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw Failure(message: "Repository URL must use public HTTPS without embedded credentials")
        }
    }

    private struct GitState {
        let commitHash: String
        let tipCommitHash: String
        let view: Repository.View
    }

    private static func gitState(at root: URL) throws -> GitState {
        let repository = try SwiftGitX.Repository.open(at: root)
        guard let commit = try repository.HEAD.target as? Commit else {
            throw Failure(message: "Repository HEAD is not a commit")
        }
        let tip = try tipCommit(in: repository)
        return GitState(
            commitHash: commit.id.hex,
            tipCommitHash: tip.id.hex,
            view: repository.isHEADDetached ? .historical : .live
        )
    }

    private static func tipCommit(in repository: SwiftGitX.Repository) throws -> Commit {
        let main = try repository.branch.get(named: "main", type: .local)
        guard let commit = main.target as? Commit else {
            throw Failure(message: "Repository main tip is not a commit")
        }
        return commit
    }

    private func installLocalRepositoryMetadata() throws {
        let manager = FileManager.default
        let destination = localRoot.appendingPathComponent(".git", isDirectory: true)
        guard !manager.fileExists(atPath: destination.path) else { return }
        guard let source = localRepositorySeed,
              manager.fileExists(atPath: source.path) else {
            throw Failure(message: "Preinitialized Local Git metadata is missing")
        }
        let staging = localRoot.deletingLastPathComponent().appendingPathComponent(".git-seed-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.copyItem(at: source, to: staging)
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        Log.service.info("ServiceRepository.git seeded repository=local")
    }

    private static func errorMessage(_ error: Error) -> String {
        guard let git = error as? SwiftGitXError else { return error.localizedDescription }
        return "\(git.message) operation=\(git.operation?.rawValue ?? "unknown") code=\(git.code.rawValue) category=\(git.category.rawValue)"
    }

    private static func stageAllChanges(in repository: SwiftGitX.Repository) throws {
        let paths = try repository.status().compactMap { entry -> String? in
            entry.workingTree?.newFile.path ?? entry.index?.newFile.path ?? entry.index?.oldFile.path
        }
        if !paths.isEmpty { try repository.add(paths: Array(Set(paths)).sorted()) }
    }

    private static func restoreAll(in repository: SwiftGitX.Repository) throws {
        let untracked = try repository.status().compactMap { entry -> String? in
            guard entry.status.contains(.workingTreeNew) else { return nil }
            return entry.workingTree?.newFile.path
        }
        try repository.restore([.workingTree, .staged])
        let root = try repository.workingDirectory.standardizedFileURL
        for path in untracked {
            let normalized = try gitPath(path)
            let url = root.appendingPathComponent(normalized).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw Failure(message: "Invalid untracked path") }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            var parent = url.deletingLastPathComponent()
            while parent.path != root.path,
                  (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try FileManager.default.removeItem(at: parent)
                parent.deleteLastPathComponent()
            }
        }
    }

    private static func restore(path: String, in repository: SwiftGitX.Repository) throws {
        let path = try gitPath(path)
        let entries = try repository.status()
        let matching = entries.filter { entry in
            let candidate = entry.workingTree?.newFile.path ?? entry.index?.newFile.path ?? entry.index?.oldFile.path
            return candidate == path
        }
        guard !matching.isEmpty else {
            throw Failure(message: "No Local change exists at \(path)")
        }
        let untracked = matching.contains { $0.status.contains(.workingTreeNew) }
        if !untracked {
            try repository.restore([.workingTree, .staged], paths: [path])
        } else {
            let root = try repository.workingDirectory.standardizedFileURL
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw Failure(message: "Invalid untracked path") }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private struct PreparedGitDiffFile {
        let path: String
        let previousPath: String?
        let change: String
        let additions: Int
        let deletions: Int
        let binary: Bool
        let patch: String
    }

    private static func gitDiff(
        repositoryID: String,
        fromCommitHash: String?,
        toCommitHash: String?,
        workingTree: Bool,
        diff: Diff,
        repository: SwiftGitX.Repository,
        root: URL,
        path: String?
    ) throws -> GitDiff {
        let patches = Dictionary(uniqueKeysWithValues: diff.patches.map { ($0.delta, $0) })
        var prepared: [PreparedGitDiffFile] = []
        for delta in diff.changes {
            let filePath = delta.type == .deleted ? delta.oldFile.path : delta.newFile.path
            guard gitPath(filePath, matches: path) else { continue }
            let patch = workingTree
                ? workingTreePatch(delta: delta, repository: repository, root: root) ?? patches[delta]
                : historicalPatch(delta: delta, repository: repository) ?? patches[delta]
            prepared.append(preparedGitDiffFile(delta: delta, patch: patch))
        }
        if workingTree {
            let included = Set(prepared.map(\.path))
            for entry in try repository.status() where entry.status.contains(.workingTreeNew) {
                guard let filePath = entry.workingTree?.newFile.path,
                      !included.contains(filePath),
                      gitPath(filePath, matches: path) else { continue }
                let fileURL = root.appendingPathComponent(filePath)
                let data = try Data(contentsOf: fileURL)
                let patch = try repository.patch(from: nil, to: fileURL)
                prepared.append(preparedGitDiffFile(
                    path: filePath,
                    previousPath: nil,
                    change: "untracked",
                    data: data,
                    patch: patch
                ))
            }
        }
        return finalizedGitDiff(
            repositoryID: repositoryID,
            fromCommitHash: fromCommitHash,
            toCommitHash: toCommitHash,
            workingTree: workingTree,
            prepared: prepared
        )
    }

    private static func gitRootDiff(
        repositoryID: String,
        commit: Commit,
        repository: SwiftGitX.Repository,
        path: String?
    ) throws -> GitDiff {
        let blobs = try gitBlobs(in: commit.tree, repository: repository)
        let prepared = try blobs.compactMap { filePath, blob -> PreparedGitDiffFile? in
            guard gitPath(filePath, matches: path) else { return nil }
            return preparedGitDiffFile(
                path: filePath,
                previousPath: nil,
                change: "added",
                data: blob.content,
                patch: try repository.patch(from: nil, to: blob)
            )
        }
        return finalizedGitDiff(
            repositoryID: repositoryID,
            fromCommitHash: nil,
            toCommitHash: commit.id.hex,
            workingTree: false,
            prepared: prepared
        )
    }

    private static func finalizedGitDiff(
        repositoryID: String,
        fromCommitHash: String?,
        toCommitHash: String?,
        workingTree: Bool,
        prepared: [PreparedGitDiffFile]
    ) -> GitDiff {
        let maximumPatchBytes = 500_000
        var patch = ""
        var files: [GitDiffFile] = []
        var truncated = false
        for item in prepared.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let included = !item.patch.isEmpty && patch.utf8.count + item.patch.utf8.count <= maximumPatchBytes
            if included {
                patch += item.patch
            } else if !item.patch.isEmpty {
                truncated = true
            }
            files.append(GitDiffFile(
                path: item.path,
                previousPath: item.previousPath,
                change: item.change,
                additions: item.additions,
                deletions: item.deletions,
                binary: item.binary,
                patchIncluded: included
            ))
        }
        return GitDiff(
            repository: repositoryID,
            fromCommitHash: fromCommitHash,
            toCommitHash: toCommitHash,
            workingTree: workingTree,
            files: files,
            patch: patch,
            truncated: truncated
        )
    }

    private static func preparedGitDiffFile(delta: Diff.Delta, patch: Patch?) -> PreparedGitDiffFile {
        let filePath = delta.type == .deleted ? delta.oldFile.path : delta.newFile.path
        let previousPath = [.renamed, .copied].contains(delta.type) && delta.oldFile.path != delta.newFile.path
            ? delta.oldFile.path
            : nil
        let binary = delta.flags.contains(.binary)
            || delta.oldFile.flags.contains(.binary)
            || delta.newFile.flags.contains(.binary)
        let rendered = renderGitPatch(
            oldPath: delta.oldFile.path,
            newPath: delta.newFile.path,
            change: gitChange(delta.type),
            binary: binary,
            patch: patch
        )
        return PreparedGitDiffFile(
            path: filePath,
            previousPath: previousPath,
            change: gitChange(delta.type),
            additions: rendered.additions,
            deletions: rendered.deletions,
            binary: binary,
            patch: rendered.text
        )
    }

    private static func preparedGitDiffFile(
        path: String,
        previousPath: String?,
        change: String,
        data: Data,
        patch: Patch
    ) -> PreparedGitDiffFile {
        let binary = data.contains(0) || String(data: data, encoding: .utf8) == nil
        let rendered = renderGitPatch(
            oldPath: path,
            newPath: path,
            change: change,
            binary: binary,
            patch: patch
        )
        return PreparedGitDiffFile(
            path: path,
            previousPath: previousPath,
            change: change,
            additions: rendered.additions,
            deletions: rendered.deletions,
            binary: binary,
            patch: rendered.text
        )
    }

    private static func renderGitPatch(
        oldPath: String,
        newPath: String,
        change: String,
        binary: Bool,
        patch: Patch?
    ) -> (text: String, additions: Int, deletions: Int) {
        let oldLabel = ["added", "untracked"].contains(change) ? "/dev/null" : "a/\(oldPath)"
        let newLabel = change == "deleted" ? "/dev/null" : "b/\(newPath)"
        var text = "diff --git a/\(oldPath) b/\(newPath)\n--- \(oldLabel)\n+++ \(newLabel)\n"
        guard !binary else {
            text += "Binary files \(oldLabel) and \(newLabel) differ\n"
            return (text, 0, 0)
        }
        var additions = 0
        var deletions = 0
        for hunk in patch?.hunks ?? [] {
            text += hunk.header
            if !hunk.header.hasSuffix("\n") { text += "\n" }
            for line in hunk.lines {
                switch line.type {
                case .context:
                    text += " " + line.content
                case .addition:
                    additions += 1
                    text += "+" + line.content
                case .deletion:
                    deletions += 1
                    text += "-" + line.content
                case .contextEOF, .additionEOF, .deletionEOF:
                    if !text.hasSuffix("\\ No newline at end of file\n") {
                        text += "\\ No newline at end of file\n"
                    }
                    continue
                }
                if !line.content.hasSuffix("\n") { text += "\n" }
            }
        }
        return (text, additions, deletions)
    }

    private static func historicalPatch(delta: Diff.Delta, repository: SwiftGitX.Repository) -> Patch? {
        do {
            let oldBlob: Blob? = delta.type == .added ? nil : try repository.show(id: delta.oldFile.id)
            let newBlob: Blob? = delta.type == .deleted ? nil : try repository.show(id: delta.newFile.id)
            return try repository.patch(from: oldBlob, to: newBlob)
        } catch {
            return nil
        }
    }

    private static func workingTreePatch(
        delta: Diff.Delta,
        repository: SwiftGitX.Repository,
        root: URL
    ) -> Patch? {
        do {
            switch delta.type {
            case .added, .untracked:
                return try repository.patch(from: nil, to: root.appendingPathComponent(delta.newFile.path))
            case .deleted:
                let oldBlob: Blob = try repository.show(id: delta.oldFile.id)
                return try repository.patch(from: oldBlob, to: nil)
            case .modified, .renamed, .copied, .typeChange:
                let oldBlob: Blob = try repository.show(id: delta.oldFile.id)
                return try repository.patch(from: oldBlob, to: root.appendingPathComponent(delta.newFile.path))
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private static func gitChange(_ type: Diff.DeltaType) -> String {
        switch type {
        case .unmodified: "unmodified"
        case .added: "added"
        case .deleted: "deleted"
        case .modified: "modified"
        case .renamed: "renamed"
        case .copied: "copied"
        case .ignored: "ignored"
        case .untracked: "untracked"
        case .typeChange: "typeChange"
        case .unreadable: "unreadable"
        case .conflicted: "conflicted"
        }
    }

    private static func gitPath(_ candidate: String, matches filter: String?) -> Bool {
        guard let filter else { return true }
        return candidate == filter || candidate.hasPrefix(filter + "/")
    }

    private static func gitBlobs(
        in tree: Tree,
        repository: SwiftGitX.Repository,
        prefix: String = ""
    ) throws -> [(String, Blob)] {
        var blobs: [(String, Blob)] = []
        for entry in tree.entries {
            let path = prefix.isEmpty ? entry.name : "\(prefix)/\(entry.name)"
            switch entry.type {
            case .blob:
                let blob: Blob = try repository.show(id: entry.id)
                blobs.append((path, blob))
            case .tree:
                let subtree: Tree = try repository.show(id: entry.id)
                blobs += try gitBlobs(in: subtree, repository: repository, prefix: path)
            default:
                continue
            }
        }
        return blobs
    }

    private static func gitStatus(
        repositoryID: String,
        provenance: Repository.Provenance,
        root: URL
    ) throws -> GitStatus {
        let repository = try SwiftGitX.Repository.open(at: root)
        let state = try gitState(at: root)
        let entries = try repository.status()
        var staged = Set<String>()
        var unstaged = Set<String>()
        var untracked = Set<String>()
        for entry in entries {
            let path = entry.workingTree?.newFile.path ?? entry.index?.newFile.path ?? entry.index?.oldFile.path
            guard let path else { continue }
            if entry.status.contains(.workingTreeNew) { untracked.insert(path) }
            if entry.status.contains(where: { [.indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange, .conflicted].contains($0) }) {
                staged.insert(path)
            }
            if entry.status.contains(where: { [.workingTreeModified, .workingTreeDeleted, .workingTreeRenamed, .workingTreeTypeChange, .workingTreeUnreadable, .conflicted].contains($0) }) {
                unstaged.insert(path)
            }
        }
        return GitStatus(
            repository: repositoryID,
            provenance: provenance.rawValue,
            view: state.view.rawValue,
            commitHash: state.commitHash,
            tipCommitHash: state.tipCommitHash,
            staged: staged.sorted(),
            unstaged: unstaged.sorted(),
            untracked: untracked.sorted(),
            dirty: !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty
        )
    }

    private static func historyCommit(_ commitHash: String, in repository: SwiftGitX.Repository) throws -> Commit {
        guard commitHash.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
            throw Failure(message: "commitHash must be a full 40-character Git commit hash")
        }
        let requested: Commit
        do {
            requested = try repository.show(id: OID(hex: commitHash))
        } catch {
            throw Failure(message: "Commit was not found in the repository")
        }
        let tip = try tipCommit(in: repository)
        guard repository.log(from: tip).contains(where: { $0.id == requested.id }) else {
            throw Failure(message: "Commit is not in the repository's linear main history")
        }
        return requested
    }

    private static func gitCommit(_ commit: Commit) throws -> GitCommit {
        GitCommit(
            commitHash: commit.id.hex,
            parentCommitHash: try commit.parents.first?.id.hex,
            summary: commit.summary,
            message: commit.message,
            committedAt: ISO8601DateFormatter().string(from: commit.date)
        )
    }

    private static func gitPath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains("\\") }) else {
            throw Failure(message: "Invalid repository path")
        }
        return components.joined(separator: "/")
    }

    private static func blob(
        at path: String,
        commit: Commit,
        repository: SwiftGitX.Repository
    ) throws -> Blob {
        var tree = try commit.tree
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            guard let entry = tree.entries.first(where: { $0.name == component }) else {
                throw Failure(message: "Path does not exist at that commit")
            }
            if index == components.count - 1 {
                guard entry.type == .blob else { throw Failure(message: "Path is not a file") }
                let blob: Blob = try repository.show(id: entry.id)
                return blob
            }
            guard entry.type == .tree else { throw Failure(message: "Path is not a directory") }
            tree = try repository.show(id: entry.id)
        }
        throw Failure(message: "Path is not a file")
    }

    private static func package(at commit: Commit, in repository: SwiftGitX.Repository) throws -> Package {
        let blob: Blob
        do {
            blob = try self.blob(at: "repository.json", commit: commit, repository: repository)
        } catch {
            blob = try self.blob(at: "ox.json", commit: commit, repository: repository)
        }
        return try JSONDecoder().decode(Package.self, from: blob.content)
    }

    private static func snapshotDate(at root: URL) -> Date? {
        try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func redacted(_ url: URL) -> String {
        guard url.user != nil || url.password != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url.absoluteString }
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? "repository"
    }
}

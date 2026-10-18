import CryptoKit
import Foundation
import SwiftGitX
import Synchronization

actor Repository {
    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
        let size: Int?
    }

    enum ServiceKind: String, Codable, Sendable {
        case web
        case api
        case iOS = "ios"
        case mcp
    }

    struct ManifestFile: Sendable {
        let repositoryID: String
        let provenance: Descriptor.Provenance
        let domain: String
        let data: Data
    }

    struct RepositoryManifestFile: Sendable {
        let repositoryID: String
        let provenance: Descriptor.Provenance
        let id: String
        let data: Data
    }

    struct Source: Sendable {
        let actions: String
    }

    struct ServiceReference: Identifiable, Equatable, Sendable {
        let id: String
        let runtimeID: String
    }

    struct Descriptor: Identifiable, Equatable, Sendable {
        enum Provenance: String, Codable, Sendable {
            case bundled
            case local
            case development
            case remote
            case mounted

            var exposesFullSource: Bool {
                switch self {
                case .bundled, .local, .mounted: true
                case .development, .remote: false
                }
            }

            var selectionPriority: Int {
                switch self {
                case .bundled: 0
                case .local: 1
                case .development: 2
                case .remote: 3
                case .mounted: 4
                }
            }
        }

        enum State: Equatable, Sendable {
            case ready
            case failed(String)
        }

        let id: String
        let name: String
        let origin: URL?
        let lastSyncedAt: Date?
        let isEnabled: Bool
        let provenance: Provenance
        let serviceCount: Int
        let services: [ServiceReference]
        let state: State
        var skills: [String] = []
        var directoryName: String? = nil
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
        let repositories: [Descriptor]
        let conflicts: [Conflict]
        let webManifests: [ManifestFile]
        let iOSManifests: [RepositoryManifestFile]
        let mcpManifests: [RepositoryManifestFile]
        let hash: String
        let skills: [Skill]
    }

    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    struct Package: Codable {
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
        var skills: [String] = []
    }

    struct ServiceID: Codable, Hashable {
        let rawValue: String
        let kind: ServiceKind
        let identity: String

        var runtimeID: String { kind == .iOS ? rawValue : identity }
        var path: String { "\(kind.rawValue)/\(identity)" }

        init(_ rawValue: String) throws {
            guard rawValue.count <= 253,
                  rawValue.range(
                    of: "^(?:web|api|ios|mcp):[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$",
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
        var directoryName: String? = nil
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
        let descriptor: Descriptor
        let root: URL
        let package: Package
        let contentRoot: URL

        init(descriptor: Descriptor, root: URL, package: Package, contentRoot: URL? = nil) {
            self.descriptor = descriptor
            self.root = root
            self.package = package
            self.contentRoot = contentRoot ?? root
        }
    }

    private struct Candidate {
        let repository: LoadedRepository
        let service: Package.Service
    }

    struct ActiveSource {
        let kind: ServiceKind
        let root: URL
        let repositoryID: String
        let provenance: Descriptor.Provenance
    }

    static let bundledID = "bundled"
    static let localID = "local"

    private let bundledRoot: URL?
    let developmentRemote: URL?
    let repositoriesRoot: URL
    let configurationURL: URL
    var configuration: Configuration
    var activeSources: [String: ActiveSource] = [:]
    var localPreparation: StoragePreparation?
    var mountedRepositories = MountedRepositoryStore()
    private var applicationRepositories: [LoadedRepository]?
    private var applicationSkills: [String: [Skill]] = [:]
    private var unmountedCatalog: MonoRepository?

    init(root: URL? = nil, developmentRemote: URL? = nil) {
        bundledRoot = root ?? Bundle.main.url(forResource: "OxServices", withExtension: "bundle")
        self.developmentRemote = developmentRemote
        repositoriesRoot = AppStoragePaths.repositories
        configurationURL = AppStoragePaths.repositoriesConfiguration
        configuration = Self.loadConfiguration(from: configurationURL)
    }

    func prepareStorage(retry: Bool = false) {
        if retry { localPreparation = nil }
        else if localPreparation?.failureMessage != nil { return }
        do {
            if localPreparation == nil { configuration = Self.loadConfiguration(from: configurationURL) }
            try materializeLocalRepository()
            localPreparation = .ready
        } catch {
            let message = Self.errorMessage(error)
            localPreparation = .needsRecovery(message)
            activeSources = activeSources.filter { $0.value.provenance != .local }
            Log.service.error("Repository.local needsRecovery=true sourcePreserved=true error=\(message)")
        }
    }

    func monoRepository(reuseApplicationRepositories: Bool = false) async throws -> MonoRepository {
        prepareStorage()
        let profileId = await StorageRoot.shared.activeId
        let grantIDs = Set(await DeviceFolderStore.shared.grants(for: profileId).map(\.id))
        let mountedRecords = ((try? mountedRepositories.records()) ?? []).filter { grantIDs.contains($0.grantID) }
        guard await StorageRoot.shared.activeId == profileId else { throw CancellationError() }
        if reuseApplicationRepositories, mountedRecords.isEmpty, let cached = unmountedCatalog {
            Log.service.info("Repository.profileSwitch reusedCatalog=true repositories=\(cached.repositories.count) skills=\(cached.skills.count)")
            return cached
        }
        unmountedCatalog = nil
        let application: [LoadedRepository]
        if reuseApplicationRepositories, let cached = applicationRepositories {
            application = cached
            Log.service.info("Repository.profileSwitch reusedRepositories=\(cached.count) reusedSkillCatalogs=\(applicationSkills.count)")
        } else {
            let bundled = loadBundledRepository()
            let development = loadDevelopmentRepository()
            let local = localPreparation?.failureMessage.map(failedLocal) ?? loadLocalRepository()
            application = [bundled, development, local].compactMap { $0 } + configuration.repositories.map(loadInstalledRepository)
            applicationRepositories = application
            applicationSkills = [:]
        }
        var mounted: [LoadedRepository] = []
        for record in mountedRecords {
            mounted.append(await loadMountedRepository(record, profileId: profileId))
        }
        guard await StorageRoot.shared.activeId == profileId else { throw CancellationError() }
        let available = application + mounted
        let loaded = available.compactMap { loaded in
            if case .ready = loaded.descriptor.state { return loaded }
            return nil
        }
        let descriptors = available.map { loaded in
            var descriptor = loaded.descriptor
            descriptor.skills = loaded.package.skills
            return descriptor
        }
        var skills: [Skill] = []
        for loaded in loaded where loaded.descriptor.isEnabled {
            let applicationOwned = loaded.descriptor.provenance != .mounted
            if applicationOwned, let cached = applicationSkills[loaded.descriptor.id] {
                skills.append(contentsOf: cached)
                continue
            }
            var repositorySkills: [Skill] = []
            for name in loaded.package.skills {
                do {
                    var skill = try SkillFiles.load(directory: loaded.contentRoot.appendingPathComponent("skills/\(name)"))
                    skill.source = .repository(id: loaded.descriptor.id, name: loaded.descriptor.name, writable: loaded.descriptor.provenance == .local)
                    repositorySkills.append(skill)
                } catch {
                    Log.service.error("Repository.skill invalid name=\(name) repository=\(loaded.descriptor.id) error=\(error.localizedDescription)")
                }
            }
            skills.append(contentsOf: repositorySkills)
            if applicationOwned { applicationSkills[loaded.descriptor.id] = repositorySkills }
        }
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
            let serviceRoot = repository.contentRoot.appendingPathComponent(service.id.path, isDirectory: true)
            let source = ActiveSource(
                kind: service.id.kind,
                root: serviceRoot,
                repositoryID: repository.descriptor.id,
                provenance: repository.descriptor.provenance
            )
            activeSources[service.id.runtimeID] = source
            let data: Data
            do {
                let manifestURL = try sourceURL(source, path: ["service.json"], legacyFallback: true)
                try Self.validateRegularFile(manifestURL, maximumSize: 512_000)
                data = try Data(contentsOf: manifestURL)
            } catch {
                Log.service.error("Repository.manifest unavailable id=\(service.id.rawValue) repository=\(repository.descriptor.id) error=\(Self.errorMessage(error))")
                continue
            }
            switch service.id.kind {
            case .web, .api:
                guard let manifest = try? JSONDecoder().decode(JSONValue.self, from: data),
                      (manifest.objectValue?["kind"]?.stringValue == "api") == (service.id.kind == .api) else {
                    Log.service.error("Repository.manifest kind-mismatch id=\(service.id.rawValue)")
                    continue
                }
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
            case .local, .mounted, .remote:
                version = try? Self.contentHash(at: repository.root, package: repository.package)
            case .bundled:
                version = try? Self.bundledContentHash(at: repository.root, package: repository.package)
            case .development:
                version = repository.package.contentHash
                    ?? (try? Self.contentHash(at: repository.root, package: repository.package))
            }
            return "\($0.service.id.rawValue):\(repository.descriptor.id):\(version ?? "unknown")"
        }.sorted().joined(separator: "\n")
        let skillInput = skills.map { "\($0.id):\(SkillFiles.serialize($0)):\(($0.resources ?? [:]).sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined())" }.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data((input + skillInput).utf8)).map { String(format: "%02x", $0) }.joined()
        Log.service.info("Repository.monoRepository repositories=\(descriptors.count) enabled=\(descriptors.count(where: \.isEnabled)) services=\(selected.count) conflicts=\(conflicts.count) hash=\(hash.prefix(12))")
        let catalog = MonoRepository(
            repositories: descriptors,
            conflicts: conflicts,
            webManifests: web,
            iOSManifests: iOS,
            mcpManifests: mcp,
            hash: hash,
            skills: skills
        )
        if mountedRecords.isEmpty { unmountedCatalog = catalog }
        return catalog
    }

    func exportLocalRepository() throws -> URL {
        if localPreparation?.failureMessage != nil { return try RepositoryMigrator.exportRecoverySource(at: localRoot) }
        try materializeLocalRepository()
        let manager = FileManager.default
        let exportRoot = manager.temporaryDirectory
            .appendingPathComponent("Ox Repository Export", isDirectory: true)
        if manager.fileExists(atPath: exportRoot.path) {
            try manager.removeItem(at: exportRoot)
        }
        try manager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let destination = exportRoot.appendingPathComponent("Local Repository", isDirectory: true)
        try manager.copyItem(at: localRoot, to: destination)
        let itemCount = manager.enumerator(at: destination, includingPropertiesForKeys: nil)?.allObjects.count ?? 0
        Log.service.info("Repository.export repository=local items=\(itemCount)")
        return destination
    }

    func prepareLocalMutation() throws {
        try materializeLocalRepository()
    }

    var localRoot: URL {
        repositoryDirectory(Self.localID)
    }

    private func materializeLocalRepository() throws {
        if let message = localPreparation?.failureMessage { throw Failure(message: message) }
        let packageURL = Self.repositoryManifestURL(at: localRoot)
        if !FileManager.default.fileExists(atPath: packageURL.path) {
            guard !FileManager.default.fileExists(atPath: localRoot.path) else {
                throw Failure(message: "Local is missing repository.json. Your files have been kept unchanged.")
            }
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
            try Self.writePackage(
                Package(version: HostProtocols.repository.last!, name: "Local", contentHash: nil, services: []),
                at: localRoot
            )
            Log.service.info("Repository.local materialized")
        }
        try RepositoryMigrator.migrateLegacyLocalServiceManifests(at: localRoot)
        try RepositoryMigrator.migrateLegacyLocalServiceActions(at: localRoot)
        try RepositoryMigrator.migrateLocalRepositoryVersion(at: localRoot)
        _ = try RepositoryMigrator.prepareRepository(at: localRoot)
        try RepositoryMigrator.migrateRemoteMCPConnections(at: localRoot) { ids in
            guard !ids.isEmpty else { return }
            for id in ids { configuration.resolutions[id] = Self.localID }
            try saveConfiguration()
        }
        _ = try Self.loadPackage(at: localRoot, provenance: .local)
    }

    private func loadLocalRepository() -> LoadedRepository {
        do {
            let package = try Self.loadPackage(at: localRoot, provenance: .local)
            return LoadedRepository(
                descriptor: Descriptor(
                    id: Self.localID,
                    name: package.name,
                    origin: nil,
                    lastSyncedAt: nil,
                    isEnabled: true,
                    provenance: .local,
                    serviceCount: package.services.count,
                    services: Self.serviceReferences(in: package),
                    state: .ready
                ),
                root: localRoot,
                package: package,
                contentRoot: try RepositoryMigrator.prepareRepository(at: localRoot)
            )
        } catch {
            return LoadedRepository(
                descriptor: Descriptor(
                    id: Self.localID,
                    name: "Local",
                    origin: nil,
                    lastSyncedAt: nil,
                    isEnabled: true,
                    provenance: .local,
                    serviceCount: 0,
                    services: [],
                    state: .failed(Self.errorMessage(error))
                ),
                root: localRoot,
                package: Package(version: HostProtocols.repository.last!, name: "Local", contentHash: nil, services: [])
            )
        }
    }

    private func failedLocal(_ message: String) -> LoadedRepository {
        LoadedRepository(
            descriptor: Descriptor(
                id: Self.localID,
                name: "Local",
                origin: nil,
                lastSyncedAt: nil,
                isEnabled: true,
                provenance: .local,
                serviceCount: 0,
                services: [],
                state: .failed(message)
            ),
            root: localRoot,
            package: Package(version: HostProtocols.repository.last!, name: "Local", contentHash: nil, services: [])
        )
    }

    private func loadBundledRepository() -> LoadedRepository {
        guard let bundledRoot else {
            return failedBundled("OxServices.bundle is missing")
        }
        do {
            let package = try Self.loadPackage(at: bundledRoot, provenance: .bundled)
            return LoadedRepository(
                descriptor: Descriptor(
                    id: Self.bundledID,
                    name: package.name,
                    origin: nil,
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
            descriptor: Descriptor(
                id: Self.bundledID,
                name: "Built-in",
                origin: nil,
                lastSyncedAt: nil,
                isEnabled: configuration.bundledEnabled,
                provenance: .bundled,
                serviceCount: 0,
                services: [],
                state: .failed(message)
            ),
            root: bundledRoot ?? Bundle.main.bundleURL,
            package: Package(version: HostProtocols.repository.last!, name: "Built-in", contentHash: nil, services: [])
        )
    }

    private func loadDevelopmentRepository() -> LoadedRepository? {
        guard let developmentRemote else { return nil }
        let root = AppStoragePaths.developmentRepositorySnapshot
        do {
            let package = try Self.loadPackage(at: root, provenance: .development)
            return LoadedRepository(
                descriptor: Descriptor(
                    id: "development",
                    name: package.name,
                    origin: developmentRemote,
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
                descriptor: Descriptor(
                    id: "development",
                    name: "Development Server",
                    origin: developmentRemote,
                    lastSyncedAt: Self.snapshotDate(at: root),
                    isEnabled: configuration.developmentEnabled,
                    provenance: .development,
                    serviceCount: 0,
                    services: [],
                    state: .failed(error.localizedDescription)
                ),
                root: root,
                package: Package(version: HostProtocols.repository.last!, name: "Development Server", contentHash: nil, services: [])
            )
        }
    }

    private func loadMountedRepository(_ record: MountedRepositoryStore.Record, profileId: UUID?) async -> LoadedRepository {
        do {
            let root = try await DeviceFolderStore.shared.repositoryRoot(grantID: record.grantID, relativePath: record.relativePath, profileId: profileId)
            let package = try Self.loadPackage(at: root, provenance: .mounted)
            return LoadedRepository(
                descriptor: Descriptor(
                    id: record.id, name: package.name, origin: nil,
                    lastSyncedAt: nil, isEnabled: record.isEnabled, provenance: .mounted,
                    serviceCount: package.services.count, services: Self.serviceReferences(in: package), state: .ready
                ), root: root, package: package
            )
        } catch {
            Log.service.error("Repository.mounted unavailable id=\(record.id) grant=\(record.grantID) error=\(error.localizedDescription)")
            return LoadedRepository(
                descriptor: Descriptor(
                    id: record.id, name: "files/\(record.grantID)", origin: nil,
                    lastSyncedAt: nil, isEnabled: record.isEnabled, provenance: .mounted,
                    serviceCount: 0, services: [], state: .failed(error.localizedDescription)
                ), root: repositoriesRoot, package: Package(version: HostProtocols.repository.last!, name: "Files", contentHash: nil, services: [])
            )
        }
    }

    private func loadInstalledRepository(_ stored: InstalledRepository) -> LoadedRepository {
        let root = repositoryDirectory(stored.id)
        do {
            let package = try Self.loadPackage(at: root, provenance: .remote)
            return LoadedRepository(
                descriptor: Descriptor(
                    id: stored.id,
                    name: package.name,
                    origin: stored.origin,
                    lastSyncedAt: Self.snapshotDate(at: root),
                    isEnabled: stored.isEnabled,
                    provenance: .remote,
                    serviceCount: package.services.count,
                    services: Self.serviceReferences(in: package),
                    state: .ready,
                    directoryName: stored.directoryName
                ),
                root: root,
                package: package
            )
        } catch {
            return LoadedRepository(
                descriptor: Descriptor(
                    id: stored.id,
                    name: stored.origin.host ?? "Repository",
                    origin: stored.origin,
                    lastSyncedAt: Self.snapshotDate(at: root),
                    isEnabled: stored.isEnabled,
                    provenance: .remote,
                    serviceCount: 0,
                    services: [],
                    state: .failed(error.localizedDescription),
                    directoryName: stored.directoryName
                ),
                root: root,
                package: Package(version: HostProtocols.repository.last!, name: "Invalid", contentHash: nil, services: [])
            )
        }
    }

    static func loadPackage(at root: URL, provenance: Descriptor.Provenance) throws -> Package {
        guard FileManager.default.fileExists(atPath: repositoryManifestURL(at: root).path) else {
            throw Failure(message: "The repository is missing repository.json at its root.")
        }
        let root = provenance == .mounted ? root : try RepositoryMigrator.prepareRepository(at: root)
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
        guard HostProtocols.repository.contains(package.version) else {
            throw Failure(message: HostProtocols.unsupported("repository.json", version: package.version, supported: HostProtocols.repository))
        }
        guard !package.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              package.name.count <= 100,
              package.services.count <= 256, package.skills.count <= 256,
              Set(package.skills).count == package.skills.count,
              package.skills.allSatisfy({ SkillFiles.isLocalName($0) && !SkillFiles.reservedNames.contains($0) }) else {
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
            if provenance != .local { try validateService(service, root: root) }
        }
        if provenance != .local {
            for name in package.skills { _ = try SkillFiles.load(directory: root.appendingPathComponent("skills/\(name)")) }
        }
        return package
    }

    private static func serviceReferences(in package: Package) -> [ServiceReference] {
        package.services
            .map { ServiceReference(id: $0.id.rawValue, runtimeID: $0.id.runtimeID) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func saveConfiguration() throws {
        try Self.writeConfiguration(configuration, to: configurationURL)
    }

    nonisolated static func writeConfiguration(_ configuration: Configuration, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private static func loadConfiguration(from url: URL) -> Configuration {
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              configuration.formatVersion == 1 else { return Configuration() }
        return configuration
    }

    static func errorMessage(_ error: Error) -> String {
        guard let git = error as? SwiftGitXError else { return error.localizedDescription }
        return "\(git.message) operation=\(git.operation?.rawValue ?? "unknown") code=\(git.code.rawValue) category=\(git.category.rawValue)"
    }

    private static func snapshotDate(at root: URL) -> Date? {
        try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

}

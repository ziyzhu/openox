import CryptoKit
import Foundation
import SwiftGitX

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
        var skills: [String] = []
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

    private struct ActiveSource {
        let kind: ServiceKind
        let root: URL
        let repositoryID: String
        let provenance: Descriptor.Provenance
    }

    static let bundledID = "bundled"
    static let localID = "local"

    private let bundledRoot: URL?
    private let developmentRemote: URL?
    private let repositoriesRoot: URL
    private let configurationURL: URL
    private var configuration: Configuration
    private var activeSources: [String: ActiveSource] = [:]
    private var localPreparation: StoragePreparation?
    private var mountedRepositories = MountedRepositoryStore()
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
            case .bundled, .development:
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

    func setEnabled(repositoryID: String, enabled: Bool) throws {
        if (try? mountedRepositories.records().contains(where: { $0.id == repositoryID })) == true {
            try mountedRepositories.setEnabled(repositoryID, enabled: enabled)
            return
        }
        let previous = configuration
        if repositoryID == Self.bundledID {
            configuration.bundledEnabled = enabled
        } else if repositoryID == Self.localID {
            throw Failure(message: "The Local repository is always enabled.")
        } else if repositoryID == "development", developmentRemote != nil {
            configuration.developmentEnabled = enabled
        } else if let index = configuration.repositories.firstIndex(where: { $0.id == repositoryID }) {
            configuration.repositories[index].isEnabled = enabled
        } else {
            throw Failure(message: "Repository not found")
        }
        do {
            try saveConfiguration()
        } catch {
            configuration = previous
            throw error
        }
        Log.service.info("Repository.enabled id=\(repositoryID) enabled=\(enabled)")
    }

    func setResolution(serviceID: String, repositoryID: String) async throws {
        let catalog = try await monoRepository()
        guard let conflict = catalog.conflicts.first(where: { $0.serviceID == serviceID }),
              conflict.candidates.contains(where: { $0.repositoryID == repositoryID }) else {
            throw Failure(message: "Choose an available service source from ox.repository.conflicts.")
        }
        let previous = configuration.resolutions[serviceID]
        configuration.resolutions[serviceID] = repositoryID
        do {
            try saveConfiguration()
        } catch {
            configuration.resolutions[serviceID] = previous
            throw error
        }
        Log.service.info("Repository.resolution service=\(serviceID) repository=\(repositoryID)")
    }

    func install(from origin: URL) async throws {
        try Self.validateOrigin(origin)
        guard !configuration.repositories.contains(where: { $0.origin == origin }) else {
            throw Failure(message: "Repository is already installed")
        }
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: repositoriesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppStoragePaths.repositoryStaging, withIntermediateDirectories: true)
        let staging = AppStoragePaths.repositoryStaging.appendingPathComponent("installing-\(id)", isDirectory: true)
        do {
            Log.service.info("Repository.install origin=\(Self.redacted(origin)) id=\(id)")
            let package = try await downloadSnapshot(from: origin, to: staging, provenance: .remote)
            let directoryName = try Self.availableDirectoryName(for: package.name, excluding: configuration.repositories.compactMap(\.directoryName))
            let destination = repositoriesRoot.appendingPathComponent(directoryName, isDirectory: true)
            try publishSnapshot(at: destination, staging: staging, repositoryID: id, provenance: .remote, replacingExisting: false)
            configuration.repositories.append(InstalledRepository(id: id, origin: origin, isEnabled: true, directoryName: directoryName))
            try saveConfiguration()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure(message: Self.errorMessage(error))
        }
    }

    func update(repositoryID: String) async throws {
        if (try? mountedRepositories.records().contains(where: { $0.id == repositoryID })) == true { return }
        if repositoryID == "development", let developmentRemote {
            Log.service.info("Repository.update origin=\(Self.redacted(developmentRemote)) id=development")
            try await syncDevelopmentRepository()
            return
        }
        guard let stored = configuration.repositories.first(where: { $0.id == repositoryID }) else {
            throw Failure(message: "Repository not found")
        }
        let destination = repositoryDirectory(repositoryID)
        try FileManager.default.createDirectory(at: AppStoragePaths.repositoryStaging, withIntermediateDirectories: true)
        let staging = AppStoragePaths.repositoryStaging.appendingPathComponent("updating-\(repositoryID)", isDirectory: true)
        do {
            Log.service.info("Repository.update origin=\(Self.redacted(stored.origin)) id=\(repositoryID)")
            try await replaceSnapshot(from: stored.origin, at: destination, staging: staging, repositoryID: repositoryID, provenance: .remote)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure(message: Self.errorMessage(error))
        }
    }

    func remove(repositoryID: String) throws {
        if (try? mountedRepositories.records().contains(where: { $0.id == repositoryID })) == true {
            try mountedRepositories.disconnect(repositoryID)
            return
        }
        guard repositoryID != Self.bundledID,
              repositoryID != Self.localID,
              let index = configuration.repositories.firstIndex(where: { $0.id == repositoryID })
        else { throw Failure(message: "Repository not found") }
        configuration.repositories.remove(at: index)
        configuration.resolutions = configuration.resolutions.filter { $0.value != repositoryID }
        try saveConfiguration()
        Log.service.info("Repository.remove id=\(repositoryID)")
    }

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

    private func localSource(kind: ServiceKind, id: String) throws -> ActiveSource {
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

    private func prepareLocalMutation() throws {
        try materializeLocalRepository()
    }

    private var localRoot: URL {
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

    private static func writePackage(_ package: Package, at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(package)
        data.append(0x0A)
        try data.write(to: root.appendingPathComponent("repository.json"), options: .atomic)
    }

    private static func contentHash(at root: URL, package: Package) throws -> String {
        var digest = SHA256()
        let paths = package.services.map { $0.id.path } + package.skills.map { "skills/\($0)" }
        for path in paths.sorted() {
            let serviceRoot = root.appendingPathComponent(path, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: serviceRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var files: [(path: String, url: URL)] = []
            while let url = enumerator.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink != true, values.isRegularFile == true { files.append((path + "/" + url.pathComponents.suffix(enumerator.level).joined(separator: "/"), url)) }
            }
            for file in files.sorted(by: { $0.path < $1.path }) {
                digest.update(data: Data(file.path.utf8))
                digest.update(data: try Data(contentsOf: file.url))
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

    func connectMountedRepository(path: String) async throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components[0] == "files", components.allSatisfy({ !$0.isEmpty }),
              path.utf8.count <= 2048 else { throw Failure(message: "Use files/<grant-id>[/repository-subfolder]") }
        let grantID = components[1]
        let relativePath = Array(components.dropFirst(2))
        let root = try await DeviceFolderStore.shared.repositoryRoot(grantID: grantID, relativePath: relativePath, profileId: StorageRoot.shared.activeId)
        _ = try Self.loadPackage(at: root, provenance: .mounted)
        let record = try mountedRepositories.connect(grantID: grantID, relativePath: relativePath)
        Log.service.info("Repository.mounted connected id=\(record.id) grant=\(grantID)")
        return record.id
    }

    func requireMountedAccess(_ id: String) async throws {
        guard let record = try mountedRepositories.records().first(where: { $0.id == id }), record.isEnabled else {
            throw Failure(message: "Mounted repository is disconnected or disabled")
        }
        _ = try await DeviceFolderStore.shared.repositoryRoot(grantID: record.grantID, relativePath: record.relativePath, profileId: StorageRoot.shared.activeId)
    }

    func disconnectMountedRepository(_ id: String) throws {
        try mountedRepositories.disconnect(id)
        activeSources = activeSources.filter { $0.value.repositoryID != id }
        Log.service.info("Repository.mounted disconnected id=\(id)")
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

    private static func loadPackage(at root: URL, provenance: Descriptor.Provenance) throws -> Package {
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
        if [.web, .api].contains(service.id.kind) {
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
              Set(object.keys).isSubset(of: ["version", "name", "contentHash", "services", "skills"]),
              object["services"] is [String], object["skills"] is [String]
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
        let root = AppStoragePaths.developmentRepositorySnapshot
        let staging = root.deletingLastPathComponent().appendingPathComponent(".updating-development", isDirectory: true)
        do {
            try await replaceSnapshot(from: developmentRemote, at: root, staging: staging, repositoryID: "development", provenance: .development)
        } catch {
            throw Failure(message: Self.errorMessage(error))
        }
    }

    private func downloadSnapshot(from origin: URL, to staging: URL, provenance: Descriptor.Provenance) async throws -> Package {
        try? FileManager.default.removeItem(at: staging)
        let repository = try await SwiftGitX.Repository.clone(from: origin, to: staging)
        guard let head = try repository.HEAD.target as? Commit else { throw Failure(message: "Repository HEAD is not a commit") }
        let package = try Self.loadPackage(at: staging, provenance: provenance)
        try FileManager.default.removeItem(at: staging.appendingPathComponent(".git", isDirectory: true))
        Log.service.info("Repository.snapshot downloaded provenance=\(provenance.rawValue) head=\(head.id.abbreviated)")
        return package
    }

    private func replaceSnapshot(from origin: URL, at destination: URL, staging: URL, repositoryID: String, provenance: Descriptor.Provenance) async throws {
        do {
            _ = try await downloadSnapshot(from: origin, to: staging, provenance: provenance)
            try publishSnapshot(at: destination, staging: staging, repositoryID: repositoryID, provenance: provenance)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func publishSnapshot(at destination: URL, staging: URL, repositoryID: String, provenance: Descriptor.Provenance, replacingExisting: Bool = true) throws {
        let manager = FileManager.default
        let backup = staging.deletingLastPathComponent().appendingPathComponent("repository-backup-\(repositoryID)", isDirectory: true)
        guard !manager.fileExists(atPath: backup.path) else {
            throw Failure(message: "A repository update needs recovery. Reopen Ox to recover its files before syncing again.")
        }
        var movedExisting = false
        if manager.fileExists(atPath: destination.path) {
            guard replacingExisting else { throw Failure(message: "A folder already exists at Repositories/\(destination.lastPathComponent). Try connecting again.") }
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
        if provenance == .development { try? AppStoragePaths.excludeFromBackup(destination) }
        if movedExisting {
            do {
                try manager.removeItem(at: backup)
            } catch {
                Log.service.warning("Repository.snapshot backup cleanup failed error=\(error.localizedDescription)")
            }
        }
        Log.service.info("Repository.snapshot installed provenance=\(provenance.rawValue) id=\(repositoryID) folder=\(destination.lastPathComponent)")
    }

    private func repositoryDirectory(_ id: String) -> URL {
        let name = id == Self.localID ? "Local" : configuration.repositories.first { $0.id == id }?.directoryName ?? id
        return repositoriesRoot.appendingPathComponent(name, isDirectory: true)
    }

    nonisolated static func isDirectoryName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && name.utf8.count <= 240
            && name.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "/\\:<>\"|?*"))) == nil
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    nonisolated static func availableDirectoryName(for name: String, excluding reserved: [String]) throws -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:<>\"|?*"))
        let cleaned = name.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var base = ""
        for character in cleaned {
            guard base.utf8.count + String(character).utf8.count <= 120 else { break }
            base.append(character)
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        if base.isEmpty { base = "Repository" }
        let names = try FileManager.default.contentsOfDirectory(atPath: AppStoragePaths.repositories.path) + reserved + ["Local"]
        let taken = Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        var candidate = base
        var suffix = 2
        while taken.contains(candidate.precomposedStringWithCanonicalMapping.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func saveConfiguration() throws {
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

    private static func validateOrigin(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw Failure(message: "Repository URL must use public HTTPS without embedded credentials")
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        guard let git = error as? SwiftGitXError else { return error.localizedDescription }
        return "\(git.message) operation=\(git.operation?.rawValue ?? "unknown") code=\(git.code.rawValue) category=\(git.category.rawValue)"
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

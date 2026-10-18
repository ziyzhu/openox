import Foundation
import SwiftGitX

extension Repository {
    func setEnabled(repositoryID: String, enabled: Bool) throws {
        if isMounted(repositoryID) {
            try mountedRepositories.setEnabled(repositoryID, enabled: enabled)
            return
        }
        let previous = configuration
        if repositoryID == Self.bundledID {
            configuration.bundledEnabled = enabled
        } else if repositoryID == Self.localID {
            throw Failure(message: "The Local repository is always enabled.")
        } else if repositoryID == Self.developmentID, developmentRemote != nil {
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
        if isMounted(repositoryID) { return }
        if repositoryID == Self.developmentID, let developmentRemote {
            Log.service.info("Repository.update origin=\(Self.redacted(developmentRemote)) id=\(Self.developmentID)")
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
        if isMounted(repositoryID) {
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
        guard let record = try mountedRecord(id), record.isEnabled else {
            throw Failure(message: "Mounted repository is disconnected or disabled")
        }
        _ = try await DeviceFolderStore.shared.repositoryRoot(grantID: record.grantID, relativePath: record.relativePath, profileId: StorageRoot.shared.activeId)
    }

    func mountedRecord(_ id: String) throws -> MountedRepositoryStore.Record? {
        try mountedRepositories.records().first { $0.id == id }
    }

    private func isMounted(_ id: String) -> Bool {
        (try? mountedRecord(id)) != nil
    }

    func disconnectMountedRepository(_ id: String) throws {
        try mountedRepositories.disconnect(id)
        activeSources = activeSources.filter { $0.value.repositoryID != id }
        Log.service.info("Repository.mounted disconnected id=\(id)")
    }

    private func syncDevelopmentRepository() async throws {
        guard let developmentRemote else { return }
        let root = AppStoragePaths.developmentRepositorySnapshot
        let staging = root.deletingLastPathComponent().appendingPathComponent(".updating-development", isDirectory: true)
        do {
            try await replaceSnapshot(from: developmentRemote, at: root, staging: staging, repositoryID: Self.developmentID, provenance: .development)
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

    func repositoryDirectory(_ id: String) -> URL {
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

    private static func validateOrigin(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw Failure(message: "Repository URL must use public HTTPS without embedded credentials")
        }
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

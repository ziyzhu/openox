import Foundation
import Observation
import os

@MainActor
@Observable
final class StorageRoot {
    static let shared = StorageRoot()

    private(set) var profiles: [Profile] = []
    private(set) var isBusy = false
    private(set) var switchEpoch = 0
    private(set) var activeScope: ProfileScope {
        didSet {
            let scope = activeScope
            Self.scopeBox.withLock { $0 = scope }
        }
    }

    nonisolated private static let scopeBox = OSAllocatedUnfairLock<ProfileScope?>(initialState: nil)
    nonisolated static var currentScope: ProfileScope? { scopeBox.withLock { $0 } }

    var scope: ProfileScope { activeScope }
    var activeId: UUID? { activeScope.profileID }
    var root: URL { activeScope.root }
    var active: Profile? { profiles.first { $0.id == activeId } }
    var iCloudAvailable: Bool { cloudDocs != nil }

    @ObservationIgnored private let localDocs: URL
    @ObservationIgnored private let repository = ProfileRepository.shared
    @ObservationIgnored private let profileStore = ProfileStore.shared
    private var cloudDocs: URL?

    private static let activeKey = "storage.activeProfile"
    private static let defaultName = "Default"

    private var storedActiveId: UUID? {
        get { UserDefaults.standard.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.activeKey) }
    }

    private init() {
        localDocs = ProfileRepository.localDocuments()
        let scope = ProfileScope(profileID: nil, root: localDocs, location: .local)
        activeScope = scope
        Self.scopeBox.withLock { $0 = scope }
        Log.app.info("StorageRoot init local=\(self.localDocs.path) preferred=\(self.storedActiveId?.uuidString ?? "nil")")
    }

    func nameTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        let stem = ProfileRepository.cleanName(name)
        return profiles.contains { $0.id != id && $0.name.localizedCaseInsensitiveCompare(stem) == .orderedSame }
    }

    func resolve() async throws {
        cloudDocs = await ProfileRepository.cloudDocuments()
        loadSavedProfiles()
        if profiles.isEmpty, let seeded = await seedDefaultProfile() { profiles = [seeded] }
        guard let chosen = profiles.first(where: { $0.id == storedActiveId }) ?? profiles.first else {
            throw StorageMigrationError.activeProfileUnavailable
        }
        let migrated = try await StorageMigrator.migrate(chosen)
        update(migrated.id) { $0 = migrated }
        activate(migrated)
        Log.app.info("StorageRoot.resolve profiles=\(self.profiles.count) iCloud=\(self.iCloudAvailable) root=\(self.root.path)")
    }

    func refreshAvailability() async {
        cloudDocs = await ProfileRepository.cloudDocuments()
        loadSavedProfiles()
        await reconcileActive()
        Log.app.info("StorageRoot.refreshAvailability profiles=\(self.profiles.count) iCloud=\(self.iCloudAvailable)")
    }

    func revalidateActive() async {
        guard activeId != nil else { return }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        guard !(exists && isDirectory.boolValue) else { return }
        Log.app.info("StorageRoot.activeFolderMissing root=\(self.root.path)")
        loadSavedProfiles()
        await reconcileActive()
    }

    func switchTo(_ profile: Profile) async throws {
        guard profile.id != activeId else { return }
        isBusy = true
        defer { isBusy = false }
        let migrated = try await StorageMigrator.migrate(profile)
        update(migrated.id) { $0 = migrated }
        activate(migrated)
        switchEpoch += 1
    }

    func createProfile(name: String, location: Profile.Location) async throws {
        guard let base = baseDir(for: location) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let created = try await repository.createProfile(name: name, location: location, base: base)
            profiles.append(created)
            sortProfiles()
        } catch {
            Log.app.error("StorageRoot.create name=\(Self.cleanName(name)) location=\(location.rawValue) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func openProfile(at url: URL) async throws -> Profile {
        isBusy = true
        defer { isBusy = false }
        do {
            let opened = try profileStore.open(url, local: localDocs, cloud: cloudDocs)
            let migrated = try await StorageMigrator.migrate(opened)
            if let index = profiles.firstIndex(where: { $0.id == migrated.id }) {
                profiles[index] = migrated
            } else {
                profiles.append(migrated)
            }
            sortProfiles()
            activate(migrated)
            switchEpoch += 1
            Log.app.info("StorageRoot.open id=\(migrated.id) name=\(migrated.name)")
            return migrated
        } catch {
            Log.app.error("StorageRoot.open name=\(url.lastPathComponent) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func rename(_ profile: Profile, to newName: String) async throws {
        guard profile.location != .external, let base = baseDir(for: profile.location) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let renamed = try await repository.renameProfile(profile, to: newName, base: base) else { return }
            update(profile.id) { $0 = renamed }
            if profile.id == activeId {
                publish(renamed)
                switchEpoch += 1
            }
            sortProfiles()
        } catch {
            Log.app.error("StorageRoot.rename id=\(profile.id) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func move(_ profile: Profile, to location: Profile.Location) async throws {
        guard profile.location != .external,
              location != .external,
              profile.location != location,
              let base = baseDir(for: location) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let moved = try await repository.moveProfile(profile, to: location, base: base)
            update(profile.id) { $0 = moved }
            if profile.id == activeId {
                let scope = publish(moved)
                switchEpoch += 1
                if location == .iCloud { await repository.startDownloads(in: scope) }
            }
            Log.app.info("StorageRoot.move id=\(profile.id) name=\(moved.name) location=\(location.rawValue)")
        } catch {
            Log.app.error("StorageRoot.move id=\(profile.id) -> \(location.rawValue) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func remove(_ profile: Profile) async {
        isBusy = true
        defer { isBusy = false }
        do {
            if profile.location != .external { try await repository.deleteProfile(profile) }
            try profileStore.remove(profile)
            profiles.removeAll { $0.id == profile.id }
            Log.app.info("StorageRoot.remove id=\(profile.id) name=\(profile.name) location=\(profile.location.rawValue) remaining=\(self.profiles.count)")
            guard profile.id == activeId else { return }
            await fallbackToAnyProfile()
        } catch {
            Log.app.error("StorageRoot.remove id=\(profile.id) failed: \(error.localizedDescription)")
        }
    }

    static func cleanName(_ name: String) -> String {
        ProfileRepository.cleanName(name)
    }

    private func loadSavedProfiles() {
        profiles = profileStore.profiles(local: localDocs, cloud: cloudDocs)
        sortProfiles()
    }

    private func reconcileActive() async {
        guard let activeId else { return }
        if let current = profiles.first(where: { $0.id == activeId }) {
            if !isActive(current) || current.version != ProfileSchema.current {
                do {
                    let migrated = try await StorageMigrator.migrate(current)
                    update(migrated.id) { $0 = migrated }
                    activate(migrated)
                    switchEpoch += 1
                } catch {
                    Log.app.error("StorageRoot.reconcile id=\(current.id) failed: \(error.localizedDescription)")
                }
            }
            return
        }
        Log.app.info("StorageRoot.activeUnavailable id=\(activeId)")
        await fallbackToAnyProfile()
    }

    private func fallbackToAnyProfile() async {
        if let next = profiles.first {
            do {
                let migrated = try await StorageMigrator.migrate(next)
                update(migrated.id) { $0 = migrated }
                activate(migrated)
                switchEpoch += 1
            } catch {
                Log.app.error("StorageRoot.fallback id=\(next.id) failed: \(error.localizedDescription)")
            }
        } else if let seeded = await seedDefaultProfile() {
            profiles = [seeded]
            activate(seeded)
            switchEpoch += 1
        }
    }

    private func seedDefaultProfile() async -> Profile? {
        let location = Profile.Location.local
        guard let base = baseDir(for: location) else { return nil }
        do {
            let created = try await repository.createUniqueProfile(name: Self.defaultName, location: location, base: base)
            return created
        } catch {
            Log.app.error("StorageRoot.seed name=\(Self.defaultName) location=\(location.rawValue) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func activate(_ profile: Profile) {
        storedActiveId = profile.id
        let scope = publish(profile)
        sortProfiles()
        let repository = repository
        Task {
            await repository.ensureLayout(in: scope)
            if profile.location == .iCloud { await repository.startDownloads(in: scope) }
        }
        Log.app.info("StorageRoot.activate id=\(profile.id) name=\(profile.name) location=\(profile.location.rawValue) root=\(self.root.path)")
    }

    private func baseDir(for location: Profile.Location) -> URL? {
        switch location {
        case .local: localDocs
        case .iCloud: cloudDocs
        case .external: nil
        }
    }

    private func update(_ id: UUID, _ mutate: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&profiles[index])
    }

    private func isActive(_ profile: Profile) -> Bool {
        activeId == profile.id && root.standardizedFileURL == profile.url.standardizedFileURL
    }

    @discardableResult
    private func publish(_ profile: Profile) -> ProfileScope {
        guard !isActive(profile) else { return activeScope }
        let scope = ProfileScope(profileID: profile.id, root: profile.url, location: profile.location)
        activeScope = scope
        return scope
    }

    private func sortProfiles() {
        profiles.sort {
            let firstIsActive = $0.id == activeId
            let secondIsActive = $1.id == activeId
            if firstIsActive != secondIsActive { return firstIsActive }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

#if targetEnvironment(simulator)
nonisolated extension StorageRoot {
    static func replayStorageMigration(
        turns: [Turn],
        fixtures: [StorageMigrationFixture]
    ) async throws -> StorageMigrationReplay {
        try await StorageMigrator.replayStorageMigration(turns: turns, fixtures: fixtures)
    }
}
#endif

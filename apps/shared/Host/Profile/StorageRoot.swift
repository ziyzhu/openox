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
    var beforeProfileChange: (@MainActor () async throws -> Void)?
    var profileDidChange: (@MainActor () async throws -> Void)?

    private static let activeKey = "storage.activeProfile"
    private static let defaultName = "Default"

    private var storedActiveId: UUID? {
        UserDefaults.standard.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
    }

    private func storeActiveProfile(_ id: UUID) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.activeKey)
        defaults.set(id.uuidString, forKey: Self.activeKey)
        guard defaults.synchronize() else {
            defaults.set(previous, forKey: Self.activeKey)
            throw RuntimeError.bridge("The active Profile preference could not be saved")
        }
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
        let migrated = try await ProfileMigrator.migrate(chosen)
        update(migrated.id) { $0 = migrated }
        try await activate(migrated)
        Log.app.info("StorageRoot.resolve profiles=\(self.profiles.count) iCloud=\(self.iCloudAvailable) root=\(self.root.path)")
    }

    func refreshAvailability() async {
        guard !isBusy else { return }
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
        guard !isBusy else { throw RuntimeError.bridge("A Profile operation is already in progress") }
        guard profile.id != activeId else { return }
        isBusy = true
        defer { isBusy = false }
        let migrated = try await ProfileMigrator.migrate(profile)
        update(migrated.id) { $0 = migrated }
        try await activate(migrated)
        try await publishProfileChange()
    }

    func createProfile(name: String, location: Profile.Location) async throws {
        guard !isBusy else { throw RuntimeError.bridge("A Profile operation is already in progress") }
        guard let base = baseDir(for: location) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard location == .local else { throw RuntimeError.bridge("Create a local Profile; live SQLite synchronization is unsupported") }
            let created = try await ProfileMigrator.createFreshProfile(name: name, base: base)
            profiles.append(created)
            sortProfiles()
        } catch {
            Log.app.error("StorageRoot.create name=\(Self.cleanName(name)) location=\(location.rawValue) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func exportProfile(_ profile: Profile) async throws -> Data {
        guard !isBusy else { throw RuntimeError.bridge("A Profile operation is already in progress") }
        isBusy = true
        defer { isBusy = false }
        let active = profile.id == activeId
        do {
            if active { try await beforeProfileChange?() }
            let data = try await DurableProfileStore.shared.exportProfile(profile)
            if active { try await profileDidChange?() }
            return data
        } catch {
            if active { try? await profileDidChange?() }
            Log.app.error("StorageRoot.export failed profile=\(profile.id) error=\(error.localizedDescription)")
            throw error
        }
    }

    func importProfile(_ backup: ProfilePackage.Backup, name: String) async throws -> Profile {
        guard !isBusy else { throw RuntimeError.bridge("A Profile operation is already in progress") }
        guard !nameTaken(name) else { throw ProfileError.nameExists(name) }
        isBusy = true
        defer { isBusy = false }
        let profile = try await ProfileMigrator.importProfile(backup, name: name)
        profiles.append(profile)
        sortProfiles()
        return profile
    }

    func openProfile(at url: URL) async throws -> Profile {
        guard !isBusy else { throw RuntimeError.bridge("A Profile operation is already in progress") }
        isBusy = true
        defer { isBusy = false }
        do {
            let opened = try profileStore.open(url, local: localDocs, cloud: cloudDocs)
            let migrated = try await ProfileMigrator.migrate(opened)
            if let index = profiles.firstIndex(where: { $0.id == migrated.id }) {
                profiles[index] = migrated
            } else {
                profiles.append(migrated)
            }
            sortProfiles()
            try await activate(migrated)
            try await publishProfileChange()
            Log.app.info("StorageRoot.open id=\(migrated.id) name=\(migrated.name)")
            return migrated
        } catch {
            Log.app.error("StorageRoot.open name=\(url.lastPathComponent) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func rename(_ profile: Profile, to newName: String) async throws {
        guard !isBusy else { throw RuntimeError.bridge("A Profile operation is already in progress") }
        guard profile.location != .external, let base = baseDir(for: profile.location) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let renamed = try await repository.renameProfile(profile, to: newName, base: base) else { return }
            update(profile.id) { $0 = renamed }
            if profile.id == activeId {
                try await activate(renamed)
                try await publishProfileChange()
            }
            sortProfiles()
        } catch {
            Log.app.error("StorageRoot.rename id=\(profile.id) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func move(_ profile: Profile, to location: Profile.Location) async throws {
        guard !isBusy else { throw RuntimeError.bridge("A Profile operation is already in progress") }
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
                try await activate(moved)
                try await publishProfileChange()
            }
            Log.app.info("StorageRoot.move id=\(profile.id) name=\(moved.name) location=\(location.rawValue)")
        } catch {
            Log.app.error("StorageRoot.move id=\(profile.id) -> \(location.rawValue) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func remove(_ profile: Profile) async {
        guard !isBusy else { return }
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
                    let migrated = try await ProfileMigrator.migrate(current)
                    update(migrated.id) { $0 = migrated }
                    try await activate(migrated)
                    try await publishProfileChange()
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
                let migrated = try await ProfileMigrator.migrate(next)
                update(migrated.id) { $0 = migrated }
                try await activate(migrated)
                try await publishProfileChange()
            } catch {
                Log.app.error("StorageRoot.fallback id=\(next.id) failed: \(error.localizedDescription)")
            }
        } else if let seeded = await seedDefaultProfile() {
            do {
                let migrated = try await ProfileMigrator.migrate(seeded)
                profiles = [migrated]
                try await activate(migrated)
                try await publishProfileChange()
            } catch { Log.app.error("StorageRoot.seed activation failed=\(error.localizedDescription)") }
        }
    }

    private func seedDefaultProfile() async -> Profile? {
        let location = Profile.Location.local
        guard let base = baseDir(for: location) else { return nil }
        do {
            let created = try await ProfileMigrator.createFreshProfile(name: Self.defaultName, base: base, unique: true)
            return created
        } catch {
            Log.app.error("StorageRoot.seed name=\(Self.defaultName) location=\(location.rawValue) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func publishProfileChange() async throws {
        try await profileDidChange?()
        switchEpoch += 1
    }

    private func activate(_ profile: Profile) async throws {
        let scope = isActive(profile) ? activeScope : ProfileScope(profileID: profile.id, root: profile.url, location: profile.location)
        let changingProfile = activeScope.profileID != nil && activeScope.root != scope.root
        if changingProfile { try await beforeProfileChange?() }
        do {
            if changingProfile { try await DurableProfileStore.shared.close(in: activeScope) }
            _ = try await DurableProfileStore.shared.session(in: scope)
            try storeActiveProfile(profile.id)
        } catch {
            if changingProfile { try? await profileDidChange?() }
            throw error
        }
        activeScope = scope
        sortProfiles()
        Log.app.info("StorageRoot.activate id=\(profile.id) name=\(profile.name) location=\(profile.location.rawValue) root=\(self.root.path)")
    }

    private func baseDir(for location: Profile.Location) -> URL? {
        switch location {
        case .local: ProfileIO.publicProfiles
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

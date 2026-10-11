import Foundation

nonisolated enum StorageMigrationError: LocalizedError {
    case activeProfileUnavailable
    case collision(String)
    case invalidAttachment(String)
    case invalidApplicationStorage(String)
    case invalidFile(String)
    case invalidLocalRepositorySeed
    case invalidRepairedLocalRepository
    case missingFile(String)
    case missingConfig
    case localRepositoryRollbackFailed(String)
    case profileMigrationFailed(String)
    case recoveryRequired(String)
    case unsupportedProfileVersion(String, String)

    var errorDescription: String? {
        switch self {
        case .activeProfileUnavailable: "No Profile is available to open."
        case .collision(let path): "Migration destination conflicts with existing data: \(path)"
        case .invalidAttachment(let path): "Legacy attachment metadata is invalid: \(path)"
        case .invalidApplicationStorage(let component): "Stored \(component) data is not compatible with this version of Ox."
        case .invalidFile(let path): "Legacy artifact metadata is invalid: \(path)"
        case .invalidLocalRepositorySeed: "The Local repository repair seed is invalid."
        case .invalidRepairedLocalRepository: "The repaired Local repository is invalid."
        case .missingFile(let path): "Legacy artifact content is missing: \(path)"
        case .missingConfig: "The Profile configuration could not be read."
        case .localRepositoryRollbackFailed(let detail): "The Local repository repair and rollback failed: \(detail)"
        case .profileMigrationFailed(let name): "The Profile “\(name)” could not be updated safely."
        case .recoveryRequired(let message): message
        case .unsupportedProfileVersion(let name, let version):
            "The Profile “\(name)” uses data format “\(version)”, which this version of Ox does not support. Install the Ox version that last opened it or a newer one."
        }
    }
}

nonisolated enum StoragePreparation: Equatable, Sendable {
    case ready
    case needsRecovery(String)

    var failureMessage: String? {
        if case .needsRecovery(let message) = self { return message }
        return nil
    }
}

nonisolated enum StorageMigrator {
    @MainActor
    static func migrateApplicationStorage() {
        ApplicationStorageMigrator.migrate()
    }

    @MainActor
    static func prepare(storage: StorageRoot, services: ServiceManager) async throws {
        Log.app.info("StorageMigrator.prepare start")
        try ProfileMigrator.recoverPublications()
        try ProfileMigrator.privatizeAbandonedProfileStages()
        try ApplicationStorageMigrator.validateApplicationStorage()
        try CredentialMigrator.migrateLegacySecrets()
        try CredentialMigrator.migrateManagedOAuthAccounts()
        try CredentialMigrator.migratePublicationToken()
        try await storage.resolve()
        try CredentialMigrator.migrateSecretProviderKeys()
        try CredentialMigrator.removeVerifiedLegacyProviderKeys()
        await services.prepareStorage()
        let manifests = try await services.storageManifestFiles()
        try CredentialMigrator.migrateAPIServiceOAuthAccounts(manifests: manifests)
        try CredentialMigrator.migrateSecretAPIServiceCredentials(manifests: manifests)
        Log.app.info("StorageMigrator.prepare done profile=\(storage.activeId?.uuidString ?? "nil")")
    }

    @MainActor
    static func recoverOptionalStorage(services: ServiceManager, activateSchedules: @MainActor () throws -> Void) async -> Bool {
        guard !Task.isCancelled else { return false }
        if services.localRecoveryMessage != nil {
            do {
                try await services.retryLocalStorage()
                Log.app.info("StorageMigrator.recovery done resource=local")
            } catch {
                Log.app.warning("StorageMigrator.recovery deferred resource=local error=\(error.localizedDescription)")
            }
        }
        guard !Task.isCancelled else { return false }
        if ScheduledSkills.shared.preparation?.failureMessage != nil {
            do {
                try ScheduledSkills.shared.load(retry: true)
                try activateSchedules()
                Log.app.info("StorageMigrator.recovery done resource=schedules")
            } catch {
                Log.app.warning("StorageMigrator.recovery deferred resource=schedules error=\(error.localizedDescription)")
            }
        }
        return services.localRecoveryMessage == nil && ScheduledSkills.shared.preparation == .ready
    }
}

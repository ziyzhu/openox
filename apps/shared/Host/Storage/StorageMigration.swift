import Foundation

nonisolated enum StorageMigrationError: LocalizedError {
    case activeProfileUnavailable
    case externalProfileUnavailable(String?)
    case collision(String)
    case invalidAttachment(String)
    case invalidApplicationStorage(String)
    case invalidFile(String)
    case missingFile(String)
    case missingConfig
    case profileMigrationFailed(String)
    case recoveryRequired(String)
    case unsupportedProfileVersion(String, String)

    var requiresUserAction: Bool {
        switch self {
        case .activeProfileUnavailable, .externalProfileUnavailable, .unsupportedProfileVersion: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .activeProfileUnavailable: "Ox can’t find this Profile’s folder. If it’s in iCloud Drive, make sure iCloud is on, then try again."
        case .externalProfileUnavailable(let name?): "Ox can’t reach the folder for “\(name)”. If it moved, locate it to reconnect."
        case .externalProfileUnavailable(nil): "Ox can’t reach this Profile’s folder. If it moved, locate it to reconnect."
        case .collision(let path): "Migration destination conflicts with existing data: \(path)"
        case .invalidAttachment(let path): "Legacy attachment metadata is invalid: \(path)"
        case .invalidApplicationStorage(let component): "Stored \(component) data is not compatible with this version of Ox."
        case .invalidFile(let path): "Legacy artifact metadata is invalid: \(path)"
        case .missingFile(let path): "Legacy artifact content is missing: \(path)"
        case .missingConfig: "The Profile configuration could not be read."
        case .profileMigrationFailed(let name): "The Profile “\(name)” could not be updated safely."
        case .recoveryRequired(let message): message
        case .unsupportedProfileVersion(let name, _):
            "The Profile “\(name)” was saved by a newer version of Ox. Update Ox to open it."
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
    static func migrateApp() {
        ApplicationStorageMigrator.migrate()
    }

    @MainActor
    static func prepare(storage: StorageRoot, services: ServiceManager) async throws {
        Log.app.info("StorageMigrator.prepare start")
        attempt("app.publications") { try ProfileMigrator.recoverPublications() }
        attempt("app.abandonedStages") { try ProfileMigrator.privatizeAbandonedProfileStages() }
        attempt("app.validate") { try ApplicationStorageMigrator.validateApplicationStorage() }
        attempt("app.legacySecrets") { try CredentialMigrator.migrateLegacySecrets() }
        attempt("app.secretStorage") { try CredentialMigrator.migrateSecretStorage() }
        attempt("app.managedOAuth") { try CredentialMigrator.migrateManagedOAuthAccounts() }
        attempt("app.publicationToken") { try CredentialMigrator.migratePublicationToken() }
        try await storage.resolve()
        await migrateProfile(storage.scope, services: services)
        Log.app.info("StorageMigrator.prepare done profile=\(storage.activeId?.uuidString ?? "nil")")
    }

    @MainActor
    private static func migrateProfile(_ scope: ProfileScope, services: ServiceManager) async {
        if let profileID = scope.profileID { attempt("profile.credentialScope") { try CredentialMigrator.adoptIntoProfile(profileID) } }
        attempt("profile.providerKeys") { try CredentialMigrator.migrateSecretProviderKeys() }
        attempt("profile.legacyProviderKeys") { try CredentialMigrator.removeVerifiedLegacyProviderKeys() }
        do { try await Task.detached(priority: .userInitiated) { try RepositoryMigrator.migrateIntoProfile(scope) }.value }
        catch { logDeferred("profile.repositories", error) }
        await services.prepareStorage()
        do {
            let legacyAccounts = Set(try Credentials.accounts(prefix: "service:api:"))
            Log.app.info("StorageMigrator.apiServiceCredentials pending=\(legacyAccounts.count)")
            guard !legacyAccounts.isEmpty else { return }
            let manifests = try await services.storageManifestFiles()
            attempt("profile.apiServiceOAuth") { try CredentialMigrator.migrateAPIServiceOAuthAccounts(manifests: manifests, legacyAccounts: legacyAccounts) }
            attempt("profile.apiServiceCredentials") { try CredentialMigrator.migrateSecretAPIServiceCredentials(manifests: manifests, legacyAccounts: legacyAccounts) }
        } catch { logDeferred("profile.apiServiceCredentials", error) }
    }

    private static func attempt(_ step: String, _ body: () throws -> Void) {
        do { try body() } catch { logDeferred(step, error) }
    }

    private static func logDeferred(_ step: String, _ error: Error) {
        Log.app.error("StorageMigrator.deferred step=\(step) sourcePreserved=true retry=nextLaunch error=\(error.localizedDescription)")
    }
}

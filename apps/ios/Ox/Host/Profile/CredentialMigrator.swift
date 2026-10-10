import Foundation
import CryptoKit
import Security

nonisolated enum CredentialMigrator {
    static func removeLegacyRepositoryAuthorization() {
        let account = "oauth:service-repository:github"
        guard Credentials.secret(for: account) != nil else { return }
        Credentials.clearSecret(for: account)
        Log.app.info("StorageMigrator.repositoryAuthorization removedLegacy=true reauthorizationRequired=true")
    }

    static func migrateLegacySecrets() throws {
        let defaults = UserDefaults.standard
        let legacyIndexKey = "vault.index"
        let legacyAccounts = try Credentials.accounts(prefix: "vault:")
        let legacyData = defaults.data(forKey: legacyIndexKey)
        guard legacyData != nil || !legacyAccounts.isEmpty else { return }

        var convertedData: Data?
        if let legacyData {
            let data = try convertLegacySecretsIndex(legacyData)
            let converted = try JSONDecoder().decode(SecretIndex.self, from: data)
            try converted.validate()
            if let destination = defaults.data(forKey: Secret.indexKey) {
                let current = try JSONDecoder().decode(SecretIndex.self, from: destination)
                try current.validate()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(current) == encoder.encode(converted) else {
                    throw StorageMigrationError.collision(Secret.indexKey)
                }
            }
            convertedData = data
        }

        for account in legacyAccounts {
            guard let value = try Credentials.secretChecked(for: account) else { continue }
            let destination = "secret:" + String(account.dropFirst("vault:".count))
            if let current = try Credentials.secretChecked(for: destination) {
                guard current == value else { throw StorageMigrationError.collision(destination) }
            } else {
                try Credentials.setSecretChecked(value, for: destination,
                                                 accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
                guard try Credentials.secretChecked(for: destination) == value else {
                    throw StorageMigrationError.invalidApplicationStorage("secret credential")
                }
            }
        }
        if let convertedData, defaults.data(forKey: Secret.indexKey) == nil {
            defaults.set(convertedData, forKey: Secret.indexKey)
            guard defaults.data(forKey: Secret.indexKey) == convertedData else {
                throw StorageMigrationError.invalidApplicationStorage("secrets index")
            }
        }
        for account in legacyAccounts { try Credentials.deleteSecretChecked(for: account) }
        if legacyData != nil { defaults.removeObject(forKey: legacyIndexKey) }
        Log.app.info("StorageMigrator.secretsRenamed items=\(legacyAccounts.count) index=\(legacyData != nil)")
    }

    private static func convertLegacySecretsIndex(_ data: Data) throws -> Data {
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let legacyBindings = document["bindings"] as? [[String: Any]] else {
            throw StorageMigrationError.invalidApplicationStorage("legacy secrets index")
        }
        document["bindings"] = try legacyBindings.map { legacy in
            var binding = legacy
            guard binding["secretKey"] == nil,
                  let key = binding.removeValue(forKey: "vaultKey") as? String else {
                throw StorageMigrationError.invalidApplicationStorage("legacy secrets binding")
            }
            binding["secretKey"] = key
            return binding
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    @MainActor
    static func migrateSecretAPIServiceCredentials(manifests: [Repository.ManifestFile]) throws {
        var migrated = 0
        for file in manifests {
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: file.data),
                  let definition = try? ServiceDefinition(manifest: raw, repositoryID: file.repositoryID,
                                                          provenance: file.provenance),
                  definition.isAPI, let baseURL = definition.baseURL,
                  let authValue = definition.manifest.objectValue?["auth"],
                  let auth = try? APIServiceAuth(authValue) else { continue }
            if case .none = auth { continue }
            if case .oauth = auth { continue }
            let identity = Data("\(definition.repositoryID ?? ""):\(definition.domain)".utf8)
            let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let account = "service:api:\(hash)"
            guard let rawCredential = try Credentials.secretChecked(for: account),
                  let data = rawCredential.data(using: .utf8),
                  let credential = try? JSONDecoder().decode(APIServiceCredential.self, from: data),
                  credential.version == 1,
                  credential.refreshToken == nil, credential.expiresAt == nil, credential.scopes == nil else { continue }
            let authorization = try APIServiceAuthorization(definition: definition)
            guard credential.binding == authorization.binding else { continue }
            let key = "ox.api-service.\(hash.prefix(24))"
            if let binding = try Secret.binding(kind: .apiService, id: hash) {
                guard binding.configurationFingerprint == credential.binding,
                      binding.destination == baseURL.absoluteString,
                      let current = try Secret.apiServiceCredential(id: hash, fingerprint: credential.binding, auth: auth),
                      current.0 == credential.secret, current.1 == credential.username else {
                    throw StorageMigrationError.collision(account)
                }
            } else if let current = try Secret.value(key: key) {
                let expected = try secretJSON(for: credential, auth: auth)
                guard current == expected else { throw StorageMigrationError.collision(account) }
                try Secret.bind(SecretBinding(consumerKind: .apiService, consumerID: hash, secretKey: key,
                                           destination: baseURL.absoluteString,
                                           configurationFingerprint: credential.binding,
                                           requiredFields: requiredSecretFields(for: auth)))
            } else {
                try Secret.saveAPIServiceCredential(credential, id: hash, displayName: definition.name,
                                                   destination: baseURL.absoluteString, auth: auth)
            }
            guard let current = try Secret.apiServiceCredential(id: hash, fingerprint: credential.binding, auth: auth),
                  current.0 == credential.secret, current.1 == credential.username else {
                throw StorageMigrationError.invalidApplicationStorage("API service credential")
            }
            try Credentials.deleteSecretChecked(for: account)
            migrated += 1
        }
        Log.app.info("StorageMigrator.secretAPIServiceCredentials migrated=\(migrated)")
    }

    private static func secretJSON(for credential: APIServiceCredential, auth: APIServiceAuth) throws -> String {
        let fields: [String: String]
        switch auth {
        case .apiKey: fields = ["apiKey": credential.secret]
        case .bearer: fields = ["token": credential.secret]
        case .basic: fields = ["username": credential.username ?? "", "password": credential.secret]
        case .none, .oauth: throw StorageMigrationError.invalidApplicationStorage("API service authentication")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func requiredSecretFields(for auth: APIServiceAuth) -> [String] {
        switch auth {
        case .apiKey: ["apiKey"]
        case .bearer: ["token"]
        case .basic: ["password", "username"]
        case .none, .oauth: []
        }
    }

    @MainActor
    static func migrateSecretProviderKeys() throws {
        var migrated = 0
        for definition in ProviderRegistry.shared.definitions {
            let account = "api:\(definition.credentialID)"
            guard let legacy = try Credentials.secretChecked(for: account) else { continue }
            if let binding = try Secret.binding(kind: .provider, id: definition.credentialID) {
                guard binding.configurationFingerprint == Secret.providerFingerprint(definition),
                      binding.destination == definition.url.absoluteString,
                      Secret.providerKey(for: definition.credentialID) == legacy else {
                    throw StorageMigrationError.collision(account)
                }
            } else {
                let digest = SHA256.hash(data: Data(definition.credentialID.utf8))
                    .map { String(format: "%02x", $0) }.joined().prefix(24)
                let key = "ox.provider.\(digest)"
                if let existing = try Secret.value(key: key) {
                    let data = try JSONSerialization.data(withJSONObject: ["apiKey": legacy], options: [.sortedKeys])
                    guard existing == String(decoding: data, as: UTF8.self) else {
                        throw StorageMigrationError.collision(account)
                    }
                    try Secret.bindProvider(key: key, definition: definition)
                } else {
                    try Secret.saveProviderKey(legacy, definition: definition)
                }
                guard Secret.providerKey(for: definition.credentialID) == legacy else {
                    throw StorageMigrationError.invalidApplicationStorage("provider credential")
                }
            }
            try Credentials.deleteSecretChecked(for: account)
            migrated += 1
        }
        Log.app.info("StorageMigrator.secretProviderKeys migrated=\(migrated)")
    }

    @MainActor
    static func removeVerifiedLegacyProviderKeys() throws {
        let definitions = ProviderRegistry.shared.definitions
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        var aliases: [String: Set<String>] = [:]
        for definition in definitions where definition.id != definition.credentialID {
            aliases[definition.id, default: []].insert(definition.credentialID)
        }
        for bundled in ProviderRegistry.bundledDefinitions() {
            guard let definition = definitionsByID[bundled.definition.id],
                  bundled.legacyCredentialID != definition.credentialID else { continue }
            aliases[bundled.legacyCredentialID, default: []].insert(definition.credentialID)
        }
        var removed = 0
        var retained = 0
        for (sourceID, targetIDs) in aliases {
            let account = "api:\(sourceID)"
            guard let old = try Credentials.secretChecked(for: account) else { continue }
            guard targetIDs.contains(where: { Secret.providerKey(for: $0) == old }) else {
                retained += 1
                continue
            }
            try Credentials.deleteSecretChecked(for: account)
            removed += 1
        }
        Log.app.info("StorageMigrator.legacyProviderCopies removed=\(removed) retained=\(retained)")
    }

    @MainActor
    static func migrateManagedOAuthAccounts() throws {
        var moved = 0
        for id in ["chatgpt", "xai", "github-copilot", "openrouter"] {
            if try moveCredential(from: "oauth:\(id)", to: ManagedOAuthAccount.modelProvider(id)) { moved += 1 }
        }
        for definition in ProviderRegistry.shared.definitions where definition.auth.kind == .oauth {
            let old = "oauth:\(definition.credentialID)"
            if try moveCredential(from: old, to: ManagedOAuthAccount.modelProvider(definition.credentialID)) { moved += 1 }
        }
        for old in try Credentials.accounts(prefix: "oauth:mcp:") {
            let hash = String(old.dropFirst("oauth:mcp:".count))
            if try moveCredential(from: old, to: ManagedOAuthAccount.mcpService(hash)) { moved += 1 }
        }
        Log.app.info("StorageMigrator.managedOAuth moved=\(moved)")
    }

    static func migrateAPIServiceOAuthAccounts(manifests: [Repository.ManifestFile]) throws {
        var moved = 0
        for file in manifests {
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: file.data),
                  let definition = try? ServiceDefinition(manifest: raw, repositoryID: file.repositoryID,
                                                          provenance: file.provenance),
                  definition.isAPI, let authValue = definition.manifest.objectValue?["auth"],
                  let auth = try? APIServiceAuth(authValue) else { continue }
            guard case .oauth = auth else { continue }
            let identity = Data("\(definition.repositoryID ?? ""):\(definition.domain)".utf8)
            let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            if try moveCredential(from: "service:api:\(hash)", to: ManagedOAuthAccount.apiService(hash)) {
                moved += 1
            }
        }
        Log.app.info("StorageMigrator.apiServiceOAuth moved=\(moved)")
    }

    private static func moveCredential(from source: String, to destination: String) throws -> Bool {
        guard source != destination, let value = try Credentials.secretChecked(for: source) else { return false }
        if let existing = try Credentials.secretChecked(for: destination) {
            guard existing == value else { throw StorageMigrationError.collision(destination) }
        } else {
            try Credentials.setSecretChecked(value, for: destination)
            guard try Credentials.secretChecked(for: destination) == value else {
                throw StorageMigrationError.invalidApplicationStorage("managed OAuth")
            }
        }
        try Credentials.deleteSecretChecked(for: source)
        return true
    }

    static func migratePublicationToken() throws {
        let account = "pat:service-repository:github"
        guard let old = try Credentials.secretChecked(for: account) else { return }
        if let current = Secret.publicationToken() {
            guard current == old else { throw StorageMigrationError.collision(account) }
        } else {
            try Secret.savePublicationToken(old)
            guard Secret.publicationToken() == old else {
                throw StorageMigrationError.invalidApplicationStorage("repository publication token")
            }
        }
        try Credentials.deleteSecretChecked(for: account)
        Log.app.info("StorageMigrator.publicationToken migrated=1")
    }
}

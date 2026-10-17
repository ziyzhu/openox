import Foundation
import Security
import Synchronization

nonisolated enum Credentials {
    private static let service = AppConfiguration.keychainService
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlock
    private static let cache = Mutex<[String: String]>([:])

    static func key(for clientID: String) -> String? {
        Secret.providerKey(for: clientID)
    }

    static func legacyKey(for clientID: String) -> String? {
        secret(for: "api:\(clientID)")
    }

    static func set(_ key: String, for clientID: String) {
        setSecret(key, for: "api:\(clientID)")
    }

    static func clear(for clientID: String) {
        clearSecret(for: "api:\(clientID)")
    }

    static func secret(for account: String) -> String? {
        cache.withLock { cache in
            if let cached = cache[account] { return cached.isEmpty ? nil : cached }
            do {
                let value = try secretChecked(for: account)
                cache[account] = value ?? ""
                return value
            } catch {
                Log.agent.error("Credentials.read failed account=\(account) error=\(error.localizedDescription)")
                return nil
            }
        }
    }

    static func setSecret(_ secret: String, for account: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clearSecret(for: account); return }
        cache.withLock { cache in
            let status = write(account, trimmed)
            guard status == errSecSuccess else {
                Log.agent.error("Credentials.set failed account=\(account) status=\(status)")
                return
            }
            cache[account] = trimmed
            Log.agent.info("Credentials.set account=\(account) chars=\(trimmed.count)")
        }
    }

    static func setSecretChecked(_ secret: String, for account: String) throws {
        try setSecretChecked(secret, for: account, accessibility: accessibility)
    }

    static func setSecretChecked(_ secret: String, for account: String, accessibility: CFString) throws {
        try cache.withLock { cache in
            let status = write(account, secret, accessibility: accessibility)
            guard status == errSecSuccess else {
                throw keychainError(status)
            }
            cache[account] = secret
        }
    }

    static func secretChecked(for account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw RuntimeError.bridge("Stored credential is corrupt")
        }
        return value
    }

    static func accounts(prefix: String) throws -> [String] {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let items = result as? [[String: Any]] else { throw RuntimeError.bridge("Keychain account list is corrupt") }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }

    static func deleteSecretChecked(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
        cache.withLock { $0[account] = "" }
    }

    static func clearSecret(for account: String) {
        cache.withLock { cache in
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                Log.agent.error("Credentials.clear failed account=\(account) status=\(status)")
                return
            }
            cache[account] = ""
            Log.agent.info("Credentials.clear account=\(account)")
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func write(_ account: String, _ key: String, accessibility: CFString = accessibility) -> OSStatus {
        let data = Data(key.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        let status = SecItemCopyMatching(query(account) as CFDictionary, nil)
        if status == errSecSuccess {
            return SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        } else if status == errSecItemNotFound {
            var add = query(account)
            add.merge(attributes) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        Log.app.error("Credentials.keychain failed status=\(status)")
        let message: String
        switch status {
        case errSecMissingEntitlement:
            message = "This build cannot access Keychain. Install a correctly signed build of Ox."
        case errSecInteractionNotAllowed, errSecNotAvailable:
            message = "Keychain is temporarily unavailable. Unlock your device and try again."
        default:
            message = "Keychain could not be accessed (code \(status)). Try again, or contact support if this continues."
        }
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

nonisolated enum ManagedOAuthAccount {
    static func modelProvider(_ credentialID: String) -> String { "oauth:model-provider:\(credentialID)" }
    static func mcpService(_ endpointHash: String) -> String { "oauth:mcp-service:\(endpointHash)" }
    static func apiService(_ identityHash: String) -> String { "oauth:api-service:\(identityHash)" }
}

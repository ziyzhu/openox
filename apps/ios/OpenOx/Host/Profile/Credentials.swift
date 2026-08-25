import Foundation
import Security
import Synchronization

nonisolated enum Credentials {
    private static let service = AppConfiguration.keychainService
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlock
    private static let cache = Mutex<[String: String]>([:])

    static func key(for clientID: String) -> String? {
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
            let value = read(account)
            cache[account] = value ?? ""
            return value
        }
    }

    static func setSecret(_ secret: String, for account: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clearSecret(for: account); return }
        cache.withLock { cache in
            write(account, trimmed)
            cache[account] = trimmed
        }
        Log.agent.info("Credentials.set account=\(account) chars=\(trimmed.count)")
    }

    static func clearSecret(for account: String) {
        cache.withLock { cache in
            SecItemDelete(query(account) as CFDictionary)
            cache[account] = ""
        }
        Log.agent.info("Credentials.clear account=\(account)")
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private static func write(_ account: String, _ key: String) {
        let data = Data(key.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        if SecItemCopyMatching(query(account) as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        } else {
            var add = query(account)
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class PushRegistration {
    static let shared = PushRegistration()
    nonisolated static let keyAccount = "remote-agent-push-key"

    #if DEBUG
    private static let environment = "development"
    #else
    private static let environment = "production"
    #endif

    func start() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func received(token: Data) {
        do {
            let key = try Self.loadOrCreateKey()
            RemoteAgentDirectory.shared.pushDevice = .object([
                "token": .string(token.map { String(format: "%02x", $0) }.joined()),
                "environment": .string(Self.environment),
                "key": .string(key.base64EncodedString()),
                "kinds": .array(["completed", "needsAttention", "failed"].map(JSONValue.string)),
            ])
            Log.agent.info("PushRegistration.token bytes=\(token.count) environment=\(Self.environment)")
        } catch {
            Log.agent.error("PushRegistration.key failed error=\(error.localizedDescription)")
        }
    }

    func failed(_ error: Error) {
        Log.agent.warning("PushRegistration.token failed error=\(LogPrivacy.text(error.localizedDescription, limit: 200))")
    }

    private static func loadOrCreateKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfiguration.keychainService,
            kSecAttrAccount as String: keyAccount,
            kSecAttrAccessGroup as String: AppConfiguration.appGroupIdentifier,
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let found = SecItemCopyMatching(lookup as CFDictionary, &item)
        if found == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        guard found == errSecItemNotFound else { throw RuntimeError.bridge("Push key lookup failed with status \(found)") }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var insert = query
        insert[kSecValueData as String] = key
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw RuntimeError.bridge("Push key save failed with status \(added)") }
        Log.agent.info("PushRegistration.key created")
        return key
    }
}

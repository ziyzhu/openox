import CryptoKit
import Foundation
import os
import Security
import UserNotifications

nonisolated final class NotificationService: UNNotificationServiceExtension {
    private struct Message: Decodable {
        let kind: String
        let conversation: String
        let title: String
        let body: String
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.openox.notifications", category: "Push")

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        guard let sealed = request.content.userInfo["sealed"] as? String, let message = Self.open(sealed) else {
            Self.log.error("push.open failed")
            contentHandler(content)
            return
        }
        content.title = message.title
        content.body = MarkdownBlock.plainText(message.body)
        content.userInfo["remoteConversation"] = message.conversation
        content.userInfo["kind"] = message.kind
        Self.log.info("push.open kind=\(message.kind, privacy: .public)")
        contentHandler(content)
    }

    private static func open(_ sealed: String) -> Message? {
        guard let data = Data(base64Encoded: sealed), let key = key(),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return try? JSONDecoder().decode(Message.self, from: plaintext)
    }

    private static func key() -> Data? {
        guard let service = Bundle.main.object(forInfoDictionaryKey: "OXKeychainService") as? String,
              let group = Bundle.main.object(forInfoDictionaryKey: "OXAppGroupIdentifier") as? String else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "remote-agent-push-key",
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}

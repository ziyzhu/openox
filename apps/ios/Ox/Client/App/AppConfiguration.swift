import Foundation

nonisolated enum AppConfiguration {
    static let appGroupIdentifier = required("OXAppGroupIdentifier")
    static let iCloudContainerIdentifier = required("OXICloudContainerIdentifier")
    static let keychainService = required("OXKeychainService")
    static let websiteDataNamespace = required("OXWebsiteDataNamespace")
    static let agentSkillTypeIdentifier = required("OXAgentSkillTypeIdentifier")
    static let chatTypeIdentifier = required("OXChatTypeIdentifier")

    private static func required(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preconditionFailure("Missing \(key) in Info.plist")
        }
        return value
    }
}

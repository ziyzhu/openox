import Foundation
import UIKit

extension OxHostProtocol {
    struct ComposerFormattingResult: Encodable {
        let text: String
        let hasForegroundColor: Bool
        let visibleHasOrangeForeground: Bool
        let visibleHasPrimaryForeground: Bool
        let visibleHasMarkedText: Bool
    }

    struct BootstrapArtifactsResult: Encodable {
        let artifacts: [String]?
    }

    struct WebsiteDataResult: Encodable {
        let data: Data?
        let bytes: Int?
    }

    static func chatRows(_ summaries: [HostChatSummary]) -> [ChatRow] {
        summaries.map { summary in
            ChatRow(
                id: summary.id.uuidString,
                title: summary.title,
                model: summary.model.map(JSONValue.string) ?? .null,
                createdAt: iso(summary.createdAt),
                lastActivity: summary.lastActivity.map { .string(iso($0)) } ?? .null,
                active: summary.active
            )
        }
    }

    struct ChatRow: Encodable {
        let id: String
        let title: String
        let model: JSONValue
        let createdAt: String
        let lastActivity: JSONValue
        let active: Bool
    }

    struct ListChatsResult: Encodable {
        let chats: [ChatRow]?
    }

    struct ModelRow: Encodable {
        let id: String
        let providerModelID: String
        let variant: String?
        let displayName: String
        let maxTokens: Int
        let maxContext: Int
        let supportsTools: Bool
        let reasoning: Bool
        let reasoningEfforts: [String]
        let selectedReasoningEffort: String?
        let inputModalities: [String]
        let outputModalities: [String]
        let wireProtocol: String?
    }

    struct ProviderRow: Encodable {
        let id: String
        let displayName: String
        let regions: [String]
        let supportsTools: Bool
        let reasoningPolicy: String
        let promptCacheRouting: String?
        let maxTokensField: String?
        let credentialID: String
        let endpoint: String?
        let models: [ModelRow]
    }

    struct ListProvidersResult: Encodable {
        let region: String
        let providers: [ProviderRow]
    }

    struct DebugLogRow: Encodable {
        let seq: Int
        let time: String
        let level: String
        let category: String
        let thread: String
        let location: String
        let message: String
    }

    struct GetLogsResult: Encodable {
        let logs: [DebugLogRow]
        let nextCursor: String?
        let hasMore: Bool
    }

    struct RepositorySaveGateResult: Encodable {
        let entered: Bool?
    }

}

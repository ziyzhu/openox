#if targetEnvironment(simulator)
import Foundation
import UIKit

extension OxHostProtocol {
    enum Method: String, CaseIterable {
        case describe = "host.describe"
        case invokeAction = "services.invoke"
        case evaluate = "services.evaluate"
        case reloadService = "services.reload"
        case refreshServiceAuth = "services.refreshAuth"
        case listServices = "services.list"
        case syncServices = "services.sync"
        case listChats = "chats.list"
        case getChat = "chats.get"
        case listModels = "models.list"
        case getLogs = "logs.list"
        case getComposerFormatting = "debug.composer.formatting"
        case repositoryGate = "debug.repositories.saveGate"
        case replayStorageMigration = "debug.storage.replayMigration"
        case runAgent = "agents.run"
        case evaluateAgent = "agents.evaluate"
        case vmInspect = "vm.inspect"
        case vmFunctions = "vm.functions"
        case vmCall = "vm.call"
        case vmEval = "vm.eval"
        case bootstrapArtifacts = "debug.artifacts.bootstrap"
        case writeArtifact = "debug.artifacts.write"
        case exportWebsiteData = "debug.websiteData.export"
        case restoreWebsiteData = "debug.websiteData.restore"
        case setKey = "debug.providers.setKey"
        case setRegion = "debug.region.set"
        case setAttachedService = "debug.chats.attachServices"
        case setComposerDraft = "debug.composer.setDraft"
        case setComposerMarkedText = "debug.composer.setMarkedText"
        case setPasteboardImage = "debug.pasteboard.setImage"
        case setPasteboardRichText = "debug.pasteboard.setRichText"
        case stageSharedNote = "debug.share.stageNote"
        case setEditDraft = "debug.chat.setEditDraft"
    }

    struct EmptyRequest: Decodable {}

    struct SessionRequest: Decodable {
        let sessionId: String?
    }

    struct ActionRequest: Decodable {
        let domain: String
        let action: String
        let args: JSONValue?
        let approve: Bool?
    }

    struct EvaluateRequest: Decodable {
        let domain: String
        let script: String
    }

    struct ServiceRequest: Decodable {
        let domain: String
    }

    struct RunAgentRequest: Decodable {
        struct HistoryTurn: Decodable {
            let user: String
            let assistant: AssistantMessage
        }

        let sessionId: String?
        let clientId: String
        let modelId: String
        let prompt: String?
        let systemPromptOverride: String?
        let toolDescriptionOverrides: [String: String]?
        let toolParameterOverrides: [String: JSONValue]?
        let historyOverride: [HistoryTurn]?
    }

    struct SetKeyRequest: Decodable {
        let clientId: String
        let key: String?
        let region: LLMRegion?
    }

    struct SetRegionRequest: Decodable {
        let region: String
    }

    struct BootstrapArtifactInput: Decodable {
        let name: String
        let data: Data
    }

    struct BootstrapArtifactsRequest: Decodable {
        let artifacts: [BootstrapArtifactInput]
    }

    struct WriteArtifactRequest: Decodable {
        let name: String
        let data: Data
    }

    struct RestoreWebsiteDataRequest: Decodable {
        let data: Data
    }

    struct SetAttachedServiceRequest: Decodable {
        let domain: String?
        let domains: [String]?
    }

    struct PromptRequest: Decodable {
        let prompt: String
    }

    struct RepositoryGateRequest: Decodable {
        let domain: String
        let action: String
    }

    struct VMRequest: Decodable {
        let sessionId: String?
    }

    struct VMFunctionsRequest: Decodable {
        let function: String?
    }

    struct VMCallRequest: Decodable {
        let sessionId: String?
        let function: String
        let arguments: JSONValue
    }

    struct VMEvalRequest: Decodable {
        let sessionId: String?
        let script: String
    }

    struct ReplayStorageMigrationRequest: Decodable {
        let turns: [Turn]
        let fixtures: [StorageMigrationFixture]
    }

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

    struct ClientRow: Encodable {
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

    struct ListModelsResult: Encodable {
        let region: String
        let clients: [ClientRow]
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
    }

    struct RepositorySaveGateResult: Encodable {
        let entered: Bool?
    }

    struct StorageMigrationReplayResult: Encodable {
        let currentVersion: String?
        let versionUpdated: Bool?
        let ordinaryContextRemoved: Bool?
        let unreadableContextRetained: Bool?
        let compactedContextRetained: Bool?
        let compactedContextValid: Bool?
        let noContextPreserved: Bool?
        let transcriptsUnchanged: Bool?
        let secondRunNoOp: Bool?
        let ordinaryExportOmitsContext: Bool?
        let compactedExportRetainsContext: Bool?
        let defaultModelMigrated: Bool?
        let chatModelMigrated: Bool?
        let unsupportedVersionRejected: Bool?
        let providerCatalogMigrated: Bool?
        let actionPoliciesMigrated: Bool?
        let savedServicesMigrated: Bool?
        let futureActionPoliciesPreserved: Bool?
        let actionPolicyResolutionValid: Bool?
        let skillChecks: [String: Bool]?
        let secretsIndexRenamed: Bool?
        let fixtureResults: [StorageMigrationFixtureReplay]?
    }

}
#endif

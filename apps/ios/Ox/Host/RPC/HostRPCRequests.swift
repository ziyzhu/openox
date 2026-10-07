import Foundation

extension OxHostProtocol {
    static let contractVersion = 1

    enum Method: String, CaseIterable {
        case describe = "host.describe"
        case durableStorage = "debug.durable.storage"
        case durableChat = "debug.durable.chat"
        case invokeAction = "services.invoke"
        case evaluate = "services.evaluate"
        case reloadService = "services.reload"
        case refreshServiceAuth = "services.refreshAuth"
        case listServices = "services.list"
        case syncServices = "services.sync"
        case listChats = "chats.list"
        case getChat = "chats.get"
        case openChat = "chats.open"
        case respondChat = "chats.respond"
        case newChat = "chats.new"
        case sendChat = "chats.send"
        case stopChat = "chats.stop"
        case listProviders = "providers.list"
        case getLogs = "logs.list"
        case getComposerFormatting = "debug.composer.formatting"
        case repositoryGate = "debug.repositories.saveGate"
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

    struct DurableCommandParameters: Decodable {
        let caseID: String
        let action: String
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

    struct SessionRequest: Decodable {
        let sessionId: String?
    }

    struct RespondChatRequest: Decodable {
        let sessionId: String?
        let promptId: String
        let answer: String
    }

    struct NewChatRequest: Decodable {
        let temporary: Bool?
        let providerId: String?
        let modelId: String?
    }

    struct SendChatRequest: Decodable {
        let sessionId: String?
        let text: String
        let wait: Bool?
    }

    struct GetLogsRequest: Decodable {
        let limit: Int?
        let cursor: String?
        let level: String?
        let category: String?
        let query: String?
        let since: String?
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

    struct SetKeyRequest: Decodable {
        let providerId: String
        let key: String?
        let region: LLMRegion?
    }

    struct SetRegionRequest: Decodable {
        let region: String
    }

    struct SetAttachedServiceRequest: Decodable {
        let domain: String?
        let domains: [String]?
    }

    struct PromptRequest: Decodable {
        let prompt: String
    }

    struct BootstrapArtifactInput: Decodable {
        let name: String
        let data: Data
    }
}

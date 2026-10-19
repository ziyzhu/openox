import Foundation

extension OxHostProtocol {
    static let contractVersion = 2

    enum Method: String, CaseIterable {
        case describe = "host.describe"
        case listProfiles = "profiles.list"
        case inspectProfile = "profiles.inspect"
        case createProfile = "profiles.create"
        case selectProfile = "profiles.select"
        case updateProfile = "profiles.update"
        case listFolderGrants = "files.list"
        case mountFolder = "files.mount"
        case assignFolder = "files.assign"
        case unmountFolder = "files.unmount"
        case listRepositories = "repositories.list"
        case connectRepositoryFolder = "repositories.connectFolder"
        case disconnectRepositoryFolder = "repositories.disconnectFolder"
        case durableStorage = "debug.durable.storage"
        case durableConversation = "debug.durable.conversation"
        case invokeAction = "services.invoke"
        case evaluate = "services.evaluate"
        case reloadService = "services.reload"
        case refreshServiceAuth = "services.refreshAuth"
        case listServices = "services.list"
        case syncServices = "services.sync"
        case listConversations = "conversations.list"
        case getConversation = "conversations.get"
        case openConversation = "conversations.open"
        case respondConversation = "conversations.respond"
        case newConversation = "conversations.new"
        case sendConversation = "conversations.send"
        case stopConversation = "conversations.stop"
        case listProviders = "providers.list"
        case getLogs = "logs.list"
        case getComposerFormatting = "debug.composer.formatting"
        case repositoryGate = "debug.repositories.saveGate"
        case vmInspect = "vm.inspect"
        case vmFunctions = "vm.functions"
        case vmCall = "vm.call"
        case vmEval = "vm.eval"
        case bootstrapFiles = "debug.artifacts.bootstrap"
        case writeFile = "debug.artifacts.write"
        case exportWebsiteData = "debug.websiteData.export"
        case restoreWebsiteData = "debug.websiteData.restore"
        case setKey = "debug.providers.setKey"
        case setRegion = "debug.region.set"
        case setAttachedService = "debug.conversations.attachServices"
        case setComposerDraft = "debug.composer.setDraft"
        case setComposerMarkedText = "debug.composer.setMarkedText"
        case setPasteboardImage = "debug.pasteboard.setImage"
        case setPasteboardRichText = "debug.pasteboard.setRichText"
        case stageSharedNote = "debug.share.stageNote"
        case setEditDraft = "debug.conversation.setEditDraft"
    }

    struct EmptyRequest: Decodable {}

    struct ProfileRequest: Decodable {
        let profileId: String
    }

    struct CreateProfileRequest: Decodable {
        let name: String
    }

    struct UpdateProfileRequest: Decodable {
        let profileId: String
        let name: String?
        let memory: String?
        let soul: String?
    }

    struct FolderProfileRequest: Decodable {
        let profileId: String?
    }

    struct FolderGrantRequest: Decodable {
        let grantId: String
        let profileId: String?
    }

    struct MountedRepositoryRequest: Decodable {
        let path: String
    }

    struct RepositoryIDRequest: Decodable {
        let repositoryId: String
    }

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

    struct RespondConversationRequest: Decodable {
        let sessionId: String?
        let promptId: String
        let answer: String
    }

    struct NewConversationRequest: Decodable {
        let temporary: Bool?
        let providerId: String?
        let modelId: String?
    }

    struct SendConversationRequest: Decodable {
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

    struct BootstrapFilesRequest: Decodable {
        let artifacts: [BootstrapFileInput]
    }

    struct WriteFileRequest: Decodable {
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

    struct BootstrapFileInput: Decodable {
        let name: String
        let data: Data
    }
}

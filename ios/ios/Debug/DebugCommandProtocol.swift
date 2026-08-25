#if targetEnvironment(simulator)
import Foundation
import UIKit

extension DebugCommandRouter {
    struct ReducerFixtureInput: Decodable {
        let name: String
        let turns: [Turn]
    }

    enum Kind: String, Decodable {
        case invokeAction = "invoke-action"
        case evaluate
        case reloadService = "reload-service"
        case refreshServiceAuth = "refresh-service-auth"
        case listServices = "list-services"
        case syncMonoRepository = "sync-mono-repository"
        case listChats = "list-chats"
        case getChat = "get-chat"
        case listModels = "list-models"
        case getLogs = "get-logs"
        case getTranscript = "get-transcript"
        case getPerformance = "get-performance"
        case getLatestResponse = "get-latest-response"
        case getTranscriptPerformance = "get-transcript-performance"
        case getComposerFormatting = "get-composer-formatting"
        case openTranscriptFixture = "open-transcript-fixture"
        case retainBaselineSessions = "retain-baseline-sessions"
        case repositoryGate = "repository-gate"
        case replayReducer = "replay-reducer"
        case runAgent = "run-agent"
        case virtualMachineEval = "virtual-machine-eval"
        case vmInspect = "vm-inspect"
        case vmListSessions = "vm-list-sessions"
        case vmFunctions = "vm-functions"
        case vmCall = "vm-call"
        case vmEval = "vm-eval"
        case runDeadlineChat = "run-deadline-chat"
        case bootstrapArtifacts = "bootstrap-artifacts"
        case writeArtifact = "write-artifact"
        case exportWebsiteData = "export-website-data"
        case restoreWebsiteData = "restore-website-data"
        case setKey = "set-key"
        case setRegion = "set-region"
        case setAttachedService = "set-attached-service"
        case setComposerDraft = "set-composer-draft"
        case setComposerMarkedText = "set-composer-marked-text"
        case setPasteboardImage = "set-pasteboard-image"
        case setPasteboardRichText = "set-pasteboard-rich-text"
        case stageSharedNote = "stage-shared-note"
        case setEditDraft = "set-edit-draft"
    }

    struct Envelope: Decodable {
        let kind: Kind
    }

    struct IDRequest: Decodable {
        let id: String
    }

    struct SessionRequest: Decodable {
        let id: String
        let sessionId: String?
    }

    struct ActionRequest: Decodable {
        let id: String
        let domain: String
        let action: String
        let args: JSONValue?
        let approve: Bool?
    }

    struct EvaluateRequest: Decodable {
        let id: String
        let domain: String
        let script: String
    }

    struct ServiceRequest: Decodable {
        let id: String
        let domain: String
    }

    struct RunAgentRequest: Decodable {
        struct HistoryTurn: Decodable {
            let user: String
            let assistant: AssistantMessage
        }

        let id: String
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
        let id: String
        let clientId: String
        let key: String?
    }

    struct SetRegionRequest: Decodable {
        let id: String
        let region: String
    }

    struct BootstrapArtifactInput: Decodable {
        let name: String
        let data: Data
    }

    struct BootstrapArtifactsRequest: Decodable {
        let id: String
        let artifacts: [BootstrapArtifactInput]
    }

    struct WriteArtifactRequest: Decodable {
        let id: String
        let name: String
        let data: Data
    }

    struct RestoreWebsiteDataRequest: Decodable {
        let id: String
        let data: Data
    }

    struct SetAttachedServiceRequest: Decodable {
        let id: String
        let domain: String?
        let domains: [String]?
    }

    struct PromptRequest: Decodable {
        let id: String
        let prompt: String
    }

    struct RunDeadlineChatRequest: Decodable {
        let id: String
        let prompt: String
        let delayMilliseconds: Int
        let setupDelayMilliseconds: Int?
        let answerDelayMilliseconds: Int?
        let answers: [String]?
    }

    struct RepositoryGateRequest: Decodable {
        let id: String
        let domain: String
        let action: String
    }

    struct VirtualMachineEvalRequest: Decodable {
        let id: String
        let sessionId: String?
        let script: String
    }

    struct VMRequest: Decodable {
        let id: String
        let protocolVersion: Int
        let sessionId: String?
    }

    struct VMFunctionsRequest: Decodable {
        let id: String
        let protocolVersion: Int
        let function: String?
    }

    struct VMCallRequest: Decodable {
        let id: String
        let protocolVersion: Int
        let sessionId: String?
        let function: String
        let arguments: JSONValue
    }

    struct VMEvalRequest: Decodable {
        let id: String
        let protocolVersion: Int
        let sessionId: String?
        let script: String
    }

    struct CountRequest: Decodable {
        let id: String
        let count: Int
    }

    struct TurnsRequest: Decodable {
        let id: String
        let turns: Int
    }

    struct ReplayReducerRequest: Decodable {
        let id: String
        let fixtures: [ReducerFixtureInput]
    }

    enum Command: Decodable {
        case invokeAction(ActionRequest)
        case evaluate(EvaluateRequest)
        case reloadService(ServiceRequest)
        case refreshServiceAuth(ServiceRequest)
        case listServices(IDRequest)
        case syncMonoRepository(IDRequest)
        case listChats(IDRequest)
        case getChat(SessionRequest)
        case listModels(IDRequest)
        case getLogs(IDRequest)
        case getTranscript(IDRequest)
        case getPerformance(IDRequest)
        case getLatestResponse(IDRequest)
        case getTranscriptPerformance(IDRequest)
        case getComposerFormatting(IDRequest)
        case openTranscriptFixture(TurnsRequest)
        case retainBaselineSessions(CountRequest)
        case repositoryGate(RepositoryGateRequest)
        case replayReducer(ReplayReducerRequest)
        case runAgent(RunAgentRequest)
        case virtualMachineEval(VirtualMachineEvalRequest)
        case vmInspect(VMRequest)
        case vmListSessions(VMRequest)
        case vmFunctions(VMFunctionsRequest)
        case vmCall(VMCallRequest)
        case vmEval(VMEvalRequest)
        case runDeadlineChat(RunDeadlineChatRequest)
        case bootstrapArtifacts(BootstrapArtifactsRequest)
        case writeArtifact(WriteArtifactRequest)
        case exportWebsiteData(IDRequest)
        case restoreWebsiteData(RestoreWebsiteDataRequest)
        case setKey(SetKeyRequest)
        case setRegion(SetRegionRequest)
        case setAttachedService(SetAttachedServiceRequest)
        case setComposerDraft(PromptRequest)
        case setComposerMarkedText(PromptRequest)
        case setPasteboardImage(IDRequest)
        case setPasteboardRichText(PromptRequest)
        case stageSharedNote(PromptRequest)
        case setEditDraft(PromptRequest)

        init(from decoder: Decoder) throws {
            switch try Envelope(from: decoder).kind {
            case .invokeAction: self = .invokeAction(try ActionRequest(from: decoder))
            case .evaluate: self = .evaluate(try EvaluateRequest(from: decoder))
            case .reloadService: self = .reloadService(try ServiceRequest(from: decoder))
            case .refreshServiceAuth: self = .refreshServiceAuth(try ServiceRequest(from: decoder))
            case .listServices: self = .listServices(try IDRequest(from: decoder))
            case .syncMonoRepository: self = .syncMonoRepository(try IDRequest(from: decoder))
            case .listChats: self = .listChats(try IDRequest(from: decoder))
            case .getChat: self = .getChat(try SessionRequest(from: decoder))
            case .listModels: self = .listModels(try IDRequest(from: decoder))
            case .getLogs: self = .getLogs(try IDRequest(from: decoder))
            case .getTranscript: self = .getTranscript(try IDRequest(from: decoder))
            case .getPerformance: self = .getPerformance(try IDRequest(from: decoder))
            case .getLatestResponse: self = .getLatestResponse(try IDRequest(from: decoder))
            case .getTranscriptPerformance: self = .getTranscriptPerformance(try IDRequest(from: decoder))
            case .getComposerFormatting: self = .getComposerFormatting(try IDRequest(from: decoder))
            case .openTranscriptFixture: self = .openTranscriptFixture(try TurnsRequest(from: decoder))
            case .retainBaselineSessions: self = .retainBaselineSessions(try CountRequest(from: decoder))
            case .repositoryGate: self = .repositoryGate(try RepositoryGateRequest(from: decoder))
            case .replayReducer: self = .replayReducer(try ReplayReducerRequest(from: decoder))
            case .runAgent: self = .runAgent(try RunAgentRequest(from: decoder))
            case .virtualMachineEval: self = .virtualMachineEval(try VirtualMachineEvalRequest(from: decoder))
            case .vmInspect: self = .vmInspect(try VMRequest(from: decoder))
            case .vmListSessions: self = .vmListSessions(try VMRequest(from: decoder))
            case .vmFunctions: self = .vmFunctions(try VMFunctionsRequest(from: decoder))
            case .vmCall: self = .vmCall(try VMCallRequest(from: decoder))
            case .vmEval: self = .vmEval(try VMEvalRequest(from: decoder))
            case .runDeadlineChat: self = .runDeadlineChat(try RunDeadlineChatRequest(from: decoder))
            case .bootstrapArtifacts: self = .bootstrapArtifacts(try BootstrapArtifactsRequest(from: decoder))
            case .writeArtifact: self = .writeArtifact(try WriteArtifactRequest(from: decoder))
            case .exportWebsiteData: self = .exportWebsiteData(try IDRequest(from: decoder))
            case .restoreWebsiteData: self = .restoreWebsiteData(try RestoreWebsiteDataRequest(from: decoder))
            case .setKey: self = .setKey(try SetKeyRequest(from: decoder))
            case .setRegion: self = .setRegion(try SetRegionRequest(from: decoder))
            case .setAttachedService: self = .setAttachedService(try SetAttachedServiceRequest(from: decoder))
            case .setComposerDraft: self = .setComposerDraft(try PromptRequest(from: decoder))
            case .setComposerMarkedText: self = .setComposerMarkedText(try PromptRequest(from: decoder))
            case .setPasteboardImage: self = .setPasteboardImage(try IDRequest(from: decoder))
            case .setPasteboardRichText: self = .setPasteboardRichText(try PromptRequest(from: decoder))
            case .stageSharedNote: self = .stageSharedNote(try PromptRequest(from: decoder))
            case .setEditDraft: self = .setEditDraft(try PromptRequest(from: decoder))
            }
        }
    }

    struct ErrorResult: Encodable {
        let kind: String
        let error: String
    }

    struct StatusResult: Encodable {
        let kind: String
        let id: String
        let ok: Bool
        let error: String?

        init(kind: String, id: String, error: String? = nil) {
            self.kind = kind
            self.id = id
            self.ok = error == nil
            self.error = error
        }
    }

    struct ComposerFormattingResult: Encodable {
        let kind = "get-composer-formatting-result"
        let id: String
        let ok: Bool
        let text: String
        let hasForegroundColor: Bool
        let visibleHasOrangeForeground: Bool
        let visibleHasPrimaryForeground: Bool
        let visibleHasMarkedText: Bool
    }

    struct BootstrapArtifactsResult: Encodable {
        let kind = "bootstrap-artifacts-result"
        let id: String
        let ok: Bool
        let artifacts: [String]?
        let error: String?
    }

    struct WebsiteDataResult: Encodable {
        let kind: String
        let id: String
        let ok: Bool
        let data: Data?
        let bytes: Int?
        let error: String?
    }

    struct RunDeadlineChatResult: Encodable {
        let kind = "run-deadline-chat-result"
        let id: String
        let ok: Bool
        let outcome: String
        let busy: Bool
        let prompts: [String]
        let elapsedMilliseconds: Int64
        let error: String?
    }

    struct GetLatestResponseResult: Encodable {
        let kind = "get-latest-response-result"
        let id: String
        let ok: Bool
        let response: String?
    }

    @MainActor
    final class DeadlineChatInteraction {
        private let answers: [String]
        private let delay: Duration
        private var index = 0
        private(set) var prompts: [String] = []

        init(answers: [String], delayMilliseconds: Int) {
            self.answers = answers
            delay = .milliseconds(max(0, delayMilliseconds))
        }

        func respond(to request: ChatPendingPrompt) async throws -> String {
            prompts.append(request.prompt)
            try await Task.sleep(for: delay)
            let configured = answers.indices.contains(index) ? answers[index] : nil
            index += 1
            return configured.flatMap { request.options.contains($0) ? $0 : nil }
                ?? request.options.first
                ?? ""
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
        let kind = "list-chats-result"
        let id: String
        let ok: Bool
        let chats: [ChatRow]?
        let error: String?
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
        let kind = "list-models-result"
        let id: String
        let ok = true
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
        let kind = "get-logs-result"
        let id: String
        let ok = true
        let logs: [DebugLogRow]
    }

    struct GetTranscriptResult: Encodable {
        let kind = "get-transcript-result"
        let id: String
        let ok: Bool
        let transcript: ChatViewportController.DebugSnapshot?
        let error: String?
    }

    struct GetPerformanceResult: Encodable {
        let kind = "get-performance-result"
        let id: String
        let ok = true
        let data: DebugPerformance.Snapshot
    }

    struct TranscriptPerformanceResult: Encodable {
        let kind: String
        let id: String
        let ok: Bool
        let data: DebugTranscriptPerformance.Snapshot?
        let error: String?
    }

    struct RetainBaselineSessionsResult: Encodable {
        let kind = "retain-baseline-sessions-result"
        let id: String
        let ok = true
        let count: Int
    }

    struct RepositorySaveGateResult: Encodable {
        let kind = "repository-gate-result"
        let id: String
        let ok: Bool
        let entered: Bool?
        let error: String?
    }

    struct ReducerReplaySnapshot: Encodable {
        let turns: [Turn]
        let blocks: [Block]
        let blockTurns: [Int]
        let blockSources: [ReducerBlockSource]
        let wireMessages: [Message]
    }

    struct ReducerBlockSource: Encodable {
        let blockID: String
        let turnID: String
    }

    struct ReducerReplayFixture: Encodable {
        let name: String
        let snapshot: ReducerReplaySnapshot
    }

    struct ReducerReplayResult: Encodable {
        let kind = "replay-reducer-result"
        let id: String
        let ok: Bool
        let fixtures: [ReducerReplayFixture]?
        let error: String?
    }

}
#endif

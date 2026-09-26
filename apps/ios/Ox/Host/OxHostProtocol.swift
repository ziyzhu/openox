#if targetEnvironment(simulator)
import Foundation

enum OxHostProtocol {
    @MainActor
    static func handle(_ data: Data, host: any OxHost, reply: @escaping @MainActor (Data) -> Void) {
        Task { @MainActor in
            let response = await OxHostRPC.handle(data, host: host)
            guard let response else { return }
            do { reply(try JSONEncoder().encode(response)) }
            catch { Log.app.error("OxHostRPC response encoding failed error=\(error.localizedDescription)") }
        }
    }

    @MainActor
    static func invoke(_ method: Method, params: JSONValue, host: any OxHost, reply: OxHostRPC.Reply) throws {
        let data = try JSONEncoder().encode(params)
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            if type == EmptyRequest.self && params != .object([:]) {
                throw RuntimeError.bridge("This method takes no parameters")
            }
            return try JSONDecoder().decode(type, from: data)
        }
        let chats = host.chats
        let services = host.services
        switch method {
        case .describe:
            _ = try decode(EmptyRequest.self)
            reply.success(OxHostRPC.description)
        case .invokeAction: handleInvokeAction(try decode(ActionRequest.self), chatManager: chats, serviceManager: services, reply: reply)
        case .evaluate: handleEvaluate(try decode(EvaluateRequest.self), serviceManager: services, reply: reply)
        case .reloadService: handleReloadService(try decode(ServiceRequest.self), serviceManager: services, reply: reply)
        case .refreshServiceAuth: handleRefreshServiceAuth(try decode(ServiceRequest.self), serviceManager: services, reply: reply)
        case .listServices: handleListServices(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .syncServices: handleSyncServices(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .listChats: handleListChats(try decode(EmptyRequest.self), host: host, reply: reply)
        case .getChat: handleGetChat(try decode(SessionRequest.self), chatManager: chats, reply: reply)
        case .listModels: handleListModels(try decode(EmptyRequest.self), reply: reply)
        case .getLogs: handleGetLogs(try decode(EmptyRequest.self), reply: reply)
        case .getComposerFormatting: DebugUIAPI.handleGetComposerFormatting(try decode(EmptyRequest.self), reply: reply)
        case .repositoryGate: handleRepositorySaveGate(try decode(RepositoryGateRequest.self), chatManager: chats, reply: reply)
        case .replayStorageMigration: handleReplayStorageMigration(try decode(ReplayStorageMigrationRequest.self), reply: reply)
        case .evaluateAgent: handleEvaluateAgent(try decode(EvaluateAgentRequest.self), chatManager: chats, reply: reply)
        case .runAgent: handleRunAgent(try decode(RunAgentRequest.self), chatManager: chats, reply: reply)
        case .vmInspect: handleVMInspect(try decode(VMRequest.self), chatManager: chats, reply: reply)
        case .vmFunctions: handleVMFunctions(try decode(VMFunctionsRequest.self), reply: reply)
        case .vmCall: handleVMCall(try decode(VMCallRequest.self), chatManager: chats, reply: reply)
        case .vmEval: handleVMEval(try decode(VMEvalRequest.self), chatManager: chats, reply: reply)
        case .bootstrapArtifacts: handleBootstrapArtifacts(try decode(BootstrapArtifactsRequest.self), reply: reply)
        case .writeArtifact: handleWriteArtifact(try decode(WriteArtifactRequest.self), reply: reply)
        case .exportWebsiteData: handleExportWebsiteData(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .restoreWebsiteData: handleRestoreWebsiteData(try decode(RestoreWebsiteDataRequest.self), serviceManager: services, reply: reply)
        case .setKey: handleSetKey(try decode(SetKeyRequest.self), reply: reply)
        case .setRegion: handleSetRegion(try decode(SetRegionRequest.self), reply: reply)
        case .setAttachedService: handleSetAttachedService(try decode(SetAttachedServiceRequest.self), chatManager: chats, serviceManager: services, reply: reply)
        case .setComposerDraft: DebugUIAPI.handleSetComposerDraft(try decode(PromptRequest.self), reply: reply)
        case .setComposerMarkedText: DebugUIAPI.handleSetComposerMarkedText(try decode(PromptRequest.self), reply: reply)
        case .setPasteboardImage: DebugUIAPI.handleSetPasteboardImage(try decode(EmptyRequest.self), reply: reply)
        case .setPasteboardRichText: DebugUIAPI.handleSetPasteboardRichText(try decode(PromptRequest.self), reply: reply)
        case .stageSharedNote: DebugUIAPI.handleStageSharedNote(try decode(PromptRequest.self), reply: reply)
        case .setEditDraft: DebugUIAPI.handleSetEditDraft(try decode(PromptRequest.self), reply: reply)
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
}
#endif

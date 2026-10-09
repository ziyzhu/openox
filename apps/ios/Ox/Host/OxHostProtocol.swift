import Foundation

enum OxHostProtocol {
    @MainActor
    static func handle(
        _ data: Data, host: any OxHost,
        admit: @escaping @MainActor () -> String? = { nil },
        finished: @escaping @MainActor () -> Void = {},
        reply: @escaping @MainActor (Data) -> Void
    ) {
        Task { @MainActor in
            defer { finished() }
            let response = await OxHostRPC.handle(data, host: host, admit: admit)
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
        let chats = host.conversations
        let services = host.services
        switch method {
        case .durableStorage, .durableChat:
            try handleDurableExperiment(method, params: params, chats: chats, reply: reply)
        case .describe:
            _ = try decode(EmptyRequest.self)
            reply.success(OxHostRPC.description)
        case .invokeAction: handleInvokeAction(try decode(ActionRequest.self), conversationManager: chats, serviceManager: services, reply: reply)
        case .evaluate: handleEvaluate(try decode(EvaluateRequest.self), serviceManager: services, reply: reply)
        case .reloadService: handleReloadService(try decode(ServiceRequest.self), serviceManager: services, reply: reply)
        case .refreshServiceAuth: handleRefreshServiceAuth(try decode(ServiceRequest.self), serviceManager: services, reply: reply)
        case .listServices: handleListServices(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .syncServices: handleSyncServices(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .listChats: handleListChats(try decode(EmptyRequest.self), host: host, reply: reply)
        case .getChat: handleGetChat(try decode(SessionRequest.self), conversationManager: chats, reply: reply)
        case .openChat: handleOpenChat(try decode(SessionRequest.self), conversationManager: chats, reply: reply)
        case .respondChat: handleRespondChat(try decode(RespondChatRequest.self), conversationManager: chats, reply: reply)
        case .newChat: handleNewChat(try decode(NewChatRequest.self), conversationManager: chats, reply: reply)
        case .sendChat: handleSendChat(try decode(SendChatRequest.self), conversationManager: chats, reply: reply)
        case .stopChat: handleStopChat(try decode(SessionRequest.self), conversationManager: chats, reply: reply)
        case .listProviders: handleListProviders(try decode(EmptyRequest.self), reply: reply)
        case .getLogs: handleGetLogs(try decode(GetLogsRequest.self), reply: reply)
        case .getComposerFormatting: ClientAutomation.handleGetComposerFormatting(try decode(EmptyRequest.self), reply: reply)
        case .repositoryGate: handleRepositorySaveGate(try decode(RepositoryGateRequest.self), conversationManager: chats, reply: reply)
        case .vmInspect:
            let request = try decode(VMRequest.self)
            Task { await handleVMInspect(request, conversationManager: chats, reply: reply) }
        case .vmFunctions: handleVMFunctions(try decode(VMFunctionsRequest.self), reply: reply)
        case .vmCall: handleVMCall(try decode(VMCallRequest.self), conversationManager: chats, reply: reply)
        case .vmEval: handleVMEval(try decode(VMEvalRequest.self), conversationManager: chats, reply: reply)
        case .bootstrapArtifacts: handleBootstrapArtifacts(try decode(BootstrapArtifactsRequest.self), reply: reply)
        case .writeArtifact: handleWriteArtifact(try decode(WriteArtifactRequest.self), reply: reply)
        case .exportWebsiteData: handleExportWebsiteData(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .restoreWebsiteData: handleRestoreWebsiteData(try decode(RestoreWebsiteDataRequest.self), serviceManager: services, reply: reply)
        case .setKey: handleSetKey(try decode(SetKeyRequest.self), reply: reply)
        case .setRegion: handleSetRegion(try decode(SetRegionRequest.self), reply: reply)
        case .setAttachedService: handleSetAttachedService(try decode(SetAttachedServiceRequest.self), conversationManager: chats, serviceManager: services, reply: reply)
        case .setComposerDraft: ClientAutomation.handleSetComposerDraft(try decode(PromptRequest.self), reply: reply)
        case .setComposerMarkedText: ClientAutomation.handleSetComposerMarkedText(try decode(PromptRequest.self), reply: reply)
        case .setPasteboardImage: ClientAutomation.handleSetPasteboardImage(try decode(EmptyRequest.self), reply: reply)
        case .setPasteboardRichText: ClientAutomation.handleSetPasteboardRichText(try decode(PromptRequest.self), reply: reply)
        case .stageSharedNote: ClientAutomation.handleStageSharedNote(try decode(PromptRequest.self), reply: reply)
        case .setEditDraft: ClientAutomation.handleSetEditDraft(try decode(PromptRequest.self), reply: reply)
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
}

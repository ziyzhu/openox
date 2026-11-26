import Foundation

enum ProfileProtocol {
    @MainActor
    static func handle(
        _ data: Data, runtime: any ProfileRuntime,
        admit: @escaping @MainActor () -> String? = { nil },
        download: FileDownload,
        finished: @escaping @MainActor () -> Void = {},
        reply: @escaping @MainActor (Data) -> Void
    ) {
        Task { @MainActor in
            defer { finished() }
            let response = await ProfileRPC.handle(data, runtime: runtime, download: download, admit: admit)
            guard let response else { return }
            do { reply(try await response.encoded()) }
            catch { Log.app.error("ProfileRPC response encoding failed error=\(error.localizedDescription)") }
        }
    }

    @MainActor
    static func invoke(_ method: Method, params: JSONValue, runtime: any ProfileRuntime, download: FileDownload, reply: ProfileRPC.Reply) throws {
        let data = try JSONEncoder().encode(params)
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            if type == EmptyRequest.self && params != .object([:]) {
                throw RuntimeError.bridge("This method takes no parameters")
            }
            return try JSONDecoder().decode(type, from: data)
        }
        if ProfileCommands.operation != nil, method != .describe, method != .getLogs, method != .stopConversation {
            reply.failure("A Profile operation is in progress; retry after it completes")
            return
        }
        let conversations = runtime.conversations
        let services = runtime.services
        switch method {
        case .inspectProfile: handleInspectProfile(try decode(ProfileRequest.self), runtime: runtime, reply: reply)
        case .updateProfile: handleUpdateProfile(try decode(UpdateProfileRequest.self), runtime: runtime, reply: reply)
        case .listFolderGrants: handleListFolderGrants(try decode(FolderProfileRequest.self), runtime: runtime, reply: reply)
        case .mountFolder: handleMountFolder(try decode(FolderProfileRequest.self), runtime: runtime, reply: reply)
        case .assignFolder: handleAssignFolder(try decode(FolderGrantRequest.self), runtime: runtime, reply: reply)
        case .unmountFolder: handleUnmountFolder(try decode(FolderGrantRequest.self), runtime: runtime, reply: reply)
        case .downloadFile:
            let request = try decode(DownloadFileRequest.self)
            Task { await download.handle(request, conversations: conversations, reply: reply) }
        case .listRepositories: handleListRepositories(try decode(EmptyRequest.self), runtime: runtime, reply: reply)
        case .connectRepositoryFolder: handleConnectRepositoryFolder(try decode(MountedRepositoryRequest.self), runtime: runtime, reply: reply)
        case .disconnectRepositoryFolder: handleDisconnectRepositoryFolder(try decode(RepositoryIDRequest.self), runtime: runtime, reply: reply)
        case .durableStorage, .durableConversation:
            try handleDurableExperiment(method, params: params, conversations: conversations, reply: reply)
        case .describe:
            _ = try decode(EmptyRequest.self)
            reply.success(ProfileRPC.description)
        case .invokeAction: handleInvokeAction(try decode(ActionRequest.self), conversationManager: conversations, serviceManager: services, reply: reply)
        case .evaluate: handleEvaluate(try decode(EvaluateRequest.self), serviceManager: services, reply: reply)
        case .reloadService: handleReloadService(try decode(ServiceRequest.self), serviceManager: services, reply: reply)
        case .refreshServiceAuth: handleRefreshServiceAuth(try decode(ServiceRequest.self), serviceManager: services, reply: reply)
        case .listServices: handleListServices(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .syncServices: handleSyncServices(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .listConversations: handleListConversations(try decode(EmptyRequest.self), runtime: runtime, reply: reply)
        case .getConversation: handleGetConversation(try decode(ConversationRequest.self), conversationManager: conversations, reply: reply)
        case .openConversation: handleOpenConversation(try decode(ConversationRequest.self), conversationManager: conversations, reply: reply)
        case .respondConversation: handleRespondConversation(try decode(RespondConversationRequest.self), runtime: runtime, reply: reply)
        case .newConversation: handleNewConversation(try decode(NewConversationRequest.self), conversationManager: conversations, reply: reply)
        case .sendConversation: handleSendConversation(try decode(SendConversationRequest.self), runtime: runtime, reply: reply)
        case .stopConversation: handleStopConversation(try decode(ConversationRequest.self), runtime: runtime, reply: reply)
        case .listProviders: handleListProviders(try decode(EmptyRequest.self), reply: reply)
        case .listAgents: handleListAgents(try decode(EmptyRequest.self), reply: reply)
        case .addAgent: handleAddAgent(try decode(AddAgentRequest.self), reply: reply)
        case .removeAgent: handleRemoveAgent(try decode(AgentEndpointRequest.self), reply: reply)
        case .listAgentConversations: handleListAgentConversations(try decode(AgentEndpointRequest.self), conversationManager: conversations, reply: reply)
        case .getLogs: handleGetLogs(try decode(GetLogsRequest.self), reply: reply)
        case .getComposerFormatting: reply.failure("Ox on this device has no composer UI", code: -32601)
        case .repositoryGate: handleRepositorySaveGate(try decode(RepositoryGateRequest.self), conversationManager: conversations, reply: reply)
        case .vmInspect:
            let request = try decode(VMRequest.self)
            Task { await handleVMInspect(request, conversationManager: conversations, reply: reply) }
        case .vmFunctions: handleVMFunctions(try decode(VMFunctionsRequest.self), reply: reply)
        case .vmCall: handleVMCall(try decode(VMCallRequest.self), conversationManager: conversations, reply: reply)
        case .vmEval: handleVMEval(try decode(VMEvalRequest.self), conversationManager: conversations, reply: reply)
        case .bootstrapFiles: handleBootstrapFiles(try decode(BootstrapFilesRequest.self), reply: reply)
        case .writeFile: handleWriteFile(try decode(WriteFileRequest.self), reply: reply)
        case .exportWebsiteData: handleExportWebsiteData(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .restoreWebsiteData: handleRestoreWebsiteData(try decode(RestoreWebsiteDataRequest.self), serviceManager: services, reply: reply)
        case .setKey: handleSetKey(try decode(SetKeyRequest.self), reply: reply)
        case .setRegion: handleSetRegion(try decode(SetRegionRequest.self), reply: reply)
        case .setAttachedService: handleSetAttachedService(try decode(SetAttachedServiceRequest.self), conversationManager: conversations, serviceManager: services, reply: reply)
        case .setComposerDraft, .setComposerMarkedText, .setPasteboardImage, .setPasteboardRichText, .stageSharedNote, .setEditDraft:
            reply.failure("Ox on this device has no client UI", code: -32601)
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
}

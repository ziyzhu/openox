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
            do { reply(try await response.encoded()) }
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
        if HostProfileCommands.operation != nil, method != .describe, method != .getLogs, method != .stopConversation {
            reply.failure("A Host administration operation is in progress; retry after it completes")
            return
        }
        let conversations = host.conversations
        let services = host.services
        switch method {
        case .listProfiles: handleListProfiles(try decode(EmptyRequest.self), host: host, reply: reply)
        case .inspectProfile: handleInspectProfile(try decode(ProfileRequest.self), host: host, reply: reply)
        case .createProfile: handleCreateProfile(try decode(CreateProfileRequest.self), host: host, reply: reply)
        case .selectProfile: handleSelectProfile(try decode(ProfileRequest.self), host: host, reply: reply)
        case .updateProfile: handleUpdateProfile(try decode(UpdateProfileRequest.self), host: host, reply: reply)
        case .listFolderGrants: handleListFolderGrants(try decode(FolderProfileRequest.self), host: host, reply: reply)
        case .mountFolder: handleMountFolder(try decode(FolderProfileRequest.self), host: host, reply: reply)
        case .assignFolder: handleAssignFolder(try decode(FolderGrantRequest.self), host: host, reply: reply)
        case .unmountFolder: handleUnmountFolder(try decode(FolderGrantRequest.self), host: host, reply: reply)
        case .listRepositories: handleListRepositories(try decode(EmptyRequest.self), host: host, reply: reply)
        case .connectRepositoryFolder: handleConnectRepositoryFolder(try decode(MountedRepositoryRequest.self), host: host, reply: reply)
        case .disconnectRepositoryFolder: handleDisconnectRepositoryFolder(try decode(RepositoryIDRequest.self), host: host, reply: reply)
        case .durableStorage, .durableConversation:
            try handleDurableExperiment(method, params: params, conversations: conversations, reply: reply)
        case .describe:
            _ = try decode(EmptyRequest.self)
            reply.success(OxHostRPC.description)
        case .invokeAction: handleInvokeAction(try decode(ActionRequest.self), conversationManager: conversations, serviceManager: services, reply: reply)
        case .evaluate: handleEvaluate(try decode(EvaluateRequest.self), serviceManager: services, reply: reply)
        case .reloadService: handleReloadService(try decode(ServiceRequest.self), serviceManager: services, reply: reply)
        case .refreshServiceAuth: handleRefreshServiceAuth(try decode(ServiceRequest.self), serviceManager: services, reply: reply)
        case .listServices: handleListServices(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .syncServices: handleSyncServices(try decode(EmptyRequest.self), serviceManager: services, reply: reply)
        case .listConversations: handleListConversations(try decode(EmptyRequest.self), host: host, reply: reply)
        case .getConversation: handleGetConversation(try decode(SessionRequest.self), conversationManager: conversations, reply: reply)
        case .openConversation: handleOpenConversation(try decode(SessionRequest.self), conversationManager: conversations, reply: reply)
        case .respondConversation: handleRespondConversation(try decode(RespondConversationRequest.self), host: host, reply: reply)
        case .newConversation: handleNewConversation(try decode(NewConversationRequest.self), conversationManager: conversations, reply: reply)
        case .sendConversation: handleSendConversation(try decode(SendConversationRequest.self), host: host, reply: reply)
        case .stopConversation: handleStopConversation(try decode(SessionRequest.self), host: host, reply: reply)
        case .listProviders: handleListProviders(try decode(EmptyRequest.self), reply: reply)
        case .getLogs: handleGetLogs(try decode(GetLogsRequest.self), reply: reply)
        case .getComposerFormatting: reply.failure("This Host has no composer UI", code: -32601)
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
            reply.failure("This Host has no client UI", code: -32601)
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
}

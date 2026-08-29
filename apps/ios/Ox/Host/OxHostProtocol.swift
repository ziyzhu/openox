#if targetEnvironment(simulator)
import Foundation

enum OxHostProtocol {
    @MainActor
    static func handle(
        _ data: Data,
        host: any OxHost,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        let chats = host.chats
        let services = host.services
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else {
            reply(encode(ErrorResult(kind: "error", error: "invalid envelope")))
            return
        }
        switch command {
        case .invokeAction(let request): handleInvokeAction(request, chatManager: chats, serviceManager: services, reply: reply)
        case .evaluate(let request): handleEvaluate(request, serviceManager: services, reply: reply)
        case .reloadService(let request): handleReloadService(request, chatManager: chats, serviceManager: services, reply: reply)
        case .refreshServiceAuth(let request): handleRefreshServiceAuth(request, serviceManager: services, reply: reply)
        case .listServices(let request): handleListServices(request, serviceManager: services, reply: reply)
        case .syncMonoRepository(let request): handleSyncMonoRepository(request, serviceManager: services, reply: reply)
        case .listChats(let request): handleListChats(request, chatManager: chats, reply: reply)
        case .getChat(let request): handleGetChat(request, chatManager: chats, reply: reply)
        case .listModels(let request): handleListModels(request, reply: reply)
        case .getLogs(let request): handleGetLogs(request, reply: reply)
        case .getLatestResponse(let request): handleGetLatestResponse(request, chatManager: chats, reply: reply)
        case .getComposerFormatting(let request): DebugUIAPI.handleGetComposerFormatting(request, reply: reply)
        case .repositoryGate(let request): handleRepositorySaveGate(request, chatManager: chats, reply: reply)
        case .replayReducer(let request): handleReplayReducer(request, reply: reply)
        case .replayStorageMigration(let request): handleReplayStorageMigration(request, reply: reply)
        case .runAgent(let request): handleRunAgent(request, chatManager: chats, reply: reply)
        case .virtualMachineEval(let request): handleVirtualMachineEval(request, chatManager: chats, reply: reply)
        case .vmInspect(let request): handleVMInspect(request, chatManager: chats, reply: reply)
        case .vmFunctions(let request): handleVMFunctions(request, reply: reply)
        case .vmCall(let request): handleVMCall(request, chatManager: chats, reply: reply)
        case .vmEval(let request): handleVMEval(request, chatManager: chats, reply: reply)
        case .runDeadlineChat(let request): handleRunDeadlineChat(request, chatManager: chats, reply: reply)
        case .bootstrapArtifacts(let request): handleBootstrapArtifacts(request, reply: reply)
        case .writeArtifact(let request): handleWriteArtifact(request, reply: reply)
        case .exportWebsiteData(let request): handleExportWebsiteData(request, serviceManager: services, reply: reply)
        case .restoreWebsiteData(let request): handleRestoreWebsiteData(request, serviceManager: services, reply: reply)
        case .setKey(let request): handleSetKey(request, reply: reply)
        case .setRegion(let request): handleSetRegion(request, reply: reply)
        case .setAttachedService(let request): handleSetAttachedService(request, chatManager: chats, serviceManager: services, reply: reply)
        case .setComposerDraft(let request): DebugUIAPI.handleSetComposerDraft(request, reply: reply)
        case .setComposerMarkedText(let request): DebugUIAPI.handleSetComposerMarkedText(request, reply: reply)
        case .setPasteboardImage(let request): DebugUIAPI.handleSetPasteboardImage(request, reply: reply)
        case .setPasteboardRichText(let request): DebugUIAPI.handleSetPasteboardRichText(request, reply: reply)
        case .stageSharedNote(let request): DebugUIAPI.handleStageSharedNote(request, reply: reply)
        case .setEditDraft(let request): DebugUIAPI.handleSetEditDraft(request, reply: reply)
        }
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}
#endif

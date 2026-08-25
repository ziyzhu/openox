#if targetEnvironment(simulator)
import Foundation

enum DebugCommandRouter {
    @MainActor weak static var chatManager: ChatManager?
    @MainActor weak static var viewportController: ChatViewportController?
    @MainActor weak static var composer: ChatComposerModel?
    @MainActor static var setEditDraft: ((String) -> Void)?

    @MainActor
    static func handle(
        _ data: Data,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else {
            reply(encode(ErrorResult(kind: "error", error: "invalid envelope")))
            return
        }
        switch command {
        case .invokeAction(let request): handleInvokeAction(request, serviceManager: serviceManager, reply: reply)
        case .evaluate(let request): handleEvaluate(request, serviceManager: serviceManager, reply: reply)
        case .reloadService(let request): handleReloadService(request, serviceManager: serviceManager, reply: reply)
        case .refreshServiceAuth(let request): handleRefreshServiceAuth(request, serviceManager: serviceManager, reply: reply)
        case .listServices(let request): handleListServices(request, serviceManager: serviceManager, reply: reply)
        case .syncMonoRepository(let request): handleSyncMonoRepository(request, serviceManager: serviceManager, reply: reply)
        case .listChats(let request): handleListChats(request, reply: reply)
        case .getChat(let request): handleGetChat(request, reply: reply)
        case .listModels(let request): handleListModels(request, reply: reply)
        case .getLogs(let request): handleGetLogs(request, reply: reply)
        case .getTranscript(let request): handleGetTranscript(request, reply: reply)
        case .getPerformance(let request): handleGetPerformance(request, reply: reply)
        case .getLatestResponse(let request): handleGetLatestResponse(request, reply: reply)
        case .getTranscriptPerformance(let request): handleGetTranscriptPerformance(request, reply: reply)
        case .getComposerFormatting(let request): handleGetComposerFormatting(request, reply: reply)
        case .openTranscriptFixture(let request): handleOpenTranscriptFixture(request, reply: reply)
        case .retainBaselineSessions(let request): handleRetainBaselineSessions(request, reply: reply)
        case .repositoryGate(let request): handleRepositorySaveGate(request, reply: reply)
        case .replayReducer(let request): handleReplayReducer(request, reply: reply)
        case .runAgent(let request): handleRunAgent(request, reply: reply)
        case .virtualMachineEval(let request): handleVirtualMachineEval(request, reply: reply)
        case .vmInspect(let request): handleVMInspect(request, reply: reply)
        case .vmListSessions(let request): handleVMListSessions(request, reply: reply)
        case .vmFunctions(let request): handleVMFunctions(request, reply: reply)
        case .vmCall(let request): handleVMCall(request, reply: reply)
        case .vmEval(let request): handleVMEval(request, reply: reply)
        case .runDeadlineChat(let request): handleRunDeadlineChat(request, reply: reply)
        case .bootstrapArtifacts(let request): handleBootstrapArtifacts(request, reply: reply)
        case .writeArtifact(let request): handleWriteArtifact(request, reply: reply)
        case .exportWebsiteData(let request): handleExportWebsiteData(request, serviceManager: serviceManager, reply: reply)
        case .restoreWebsiteData(let request): handleRestoreWebsiteData(request, serviceManager: serviceManager, reply: reply)
        case .setKey(let request): handleSetKey(request, reply: reply)
        case .setRegion(let request): handleSetRegion(request, reply: reply)
        case .setAttachedService(let request): handleSetAttachedService(request, serviceManager: serviceManager, reply: reply)
        case .setComposerDraft(let request): handleSetComposerDraft(request, reply: reply)
        case .setComposerMarkedText(let request): handleSetComposerMarkedText(request, reply: reply)
        case .setPasteboardImage(let request): handleSetPasteboardImage(request, reply: reply)
        case .setPasteboardRichText(let request): handleSetPasteboardRichText(request, reply: reply)
        case .stageSharedNote(let request): handleStageSharedNote(request, reply: reply)
        case .setEditDraft(let request): handleSetEditDraft(request, reply: reply)
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

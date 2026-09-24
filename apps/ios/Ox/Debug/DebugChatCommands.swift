#if targetEnvironment(simulator)
import Foundation

extension OxHostProtocol {
    @MainActor
    static func handleListChats(
        _ command: EmptyRequest,
        host: any OxHost,
        reply: OxHostRPC.Reply
    ) {
        let chats = chatRows(host.listChats())
        Log.agent.debug("OxHostRPC.chats.list id=\(reply.id) count=\(chats.count)")
        reply.success(ListChatsResult(chats: chats))
    }

    @MainActor
    static func handleGetChat(
        _ command: SessionRequest,
        chatManager: ChatManager,
        reply: OxHostRPC.Reply
    ) {
        let session: Chat?
        switch resolveSession(chatManager, command.sessionId) {
        case .found(let s): session = s
        case .error(let error):
            reply.failure(error)
            return
        }
        guard let session else {
            reply.success(GetChatResult(data: nil))
            return
        }
        Log.agent.debug("OxHostRPC.chats.get id=\(reply.id) session=\(session.id)")
        reply.success(GetChatResult(data: DebugSnapshot(session)))
    }

    enum ChatLookup {
        case found(Chat?)
        case error(String)
    }

    @MainActor
    static func resolveSession(_ manager: ChatManager, _ sessionId: String?) -> ChatLookup {
        guard let sessionId, !sessionId.isEmpty else { return .found(manager.current) }
        if let session = manager.debugSession(matching: sessionId) {
            return .found(session)
        }
        return .error("unknown chat: \(sessionId)")
    }

    struct GetChatResult: Encodable {
        let data: DebugSnapshot?
    }

    @MainActor
    static func handleListModels(_ command: EmptyRequest, reply: OxHostRPC.Reply) {
        let registry = ProviderRegistry.shared
        let clients = registry.clients.map { client in
            let diagnostics = client.protocolDiagnostics
            return ClientRow(
                id: client.id,
                displayName: client.displayName,
                regions: client.regions.map(\.rawValue).sorted(),
                supportsTools: client.supportsTools,
                reasoningPolicy: client.reasoningPolicy.rawValue,
                promptCacheRouting: diagnostics.promptCacheRouting,
                maxTokensField: diagnostics.maxTokensField,
                credentialID: client.credentialID,
                endpoint: diagnostics.endpoint,
                models: client.models.map {
                    ModelRow(
                        id: $0.id,
                        providerModelID: $0.wireID,
                        variant: $0.variant?.rawValue,
                        displayName: $0.displayName,
                        maxTokens: $0.maxTokens,
                        maxContext: $0.maxContext,
                        supportsTools: client.supportsTools(for: $0),
                        reasoning: $0.reasoning,
                        reasoningEfforts: $0.reasoningEfforts,
                        selectedReasoningEffort: registry.reasoningEffort(
                            for: $0,
                            in: client.id,
                            region: registry.defaultRegion
                        ),
                        inputModalities: $0.modalities.input.map(\.rawValue).sorted(),
                        outputModalities: $0.modalities.output.map(\.rawValue).sorted(),
                        wireProtocol: client.wireProtocol(for: $0)?.rawValue
                    )
                }
            )
        }
        Log.agent.debug("OxHostRPC.models.list id=\(reply.id) count=\(clients.count)")
        reply.success(ListModelsResult(region: AppRegion.shared.region.rawValue, clients: clients))
    }

    @MainActor
    static func handleGetLogs(_ command: EmptyRequest, reply: OxHostRPC.Reply) {
        let logs = LogStore.shared.snapshot().map {
            DebugLogRow(
                seq: $0.id,
                time: iso($0.date),
                level: $0.level.name,
                category: $0.category,
                thread: $0.thread,
                location: $0.location,
                message: $0.message
            )
        }
        reply.success(GetLogsResult(logs: logs))
    }

    @MainActor
    static func handleRepositorySaveGate(
        _ command: RepositoryGateRequest,
        chatManager: ChatManager,
        reply: OxHostRPC.Reply
    ) {
        guard command.domain == "save", let entered = chatManager.debugControlRepositorySaveGate(command.action) else {
            reply.failure("expected hold, release, or status for save")
            return
        }
        reply.success(RepositorySaveGateResult(entered: entered))
    }

    @MainActor
    static func handleReplayStorageMigration(
        _ command: ReplayStorageMigrationRequest,
        reply: OxHostRPC.Reply
    ) {
        Task {
            do {
                let replay = try await StorageRoot.replayStorageMigration(
                    turns: command.turns,
                    fixtures: command.fixtures
                )
                reply.success(StorageMigrationReplayResult(
                    currentVersion: replay.currentVersion,
                    versionUpdated: replay.versionUpdated,
                    ordinaryContextRemoved: replay.ordinaryContextRemoved,
                    unreadableContextRetained: replay.unreadableContextRetained,
                    compactedContextRetained: replay.compactedContextRetained,
                    compactedContextValid: replay.compactedContextValid,
                    noContextPreserved: replay.noContextPreserved,
                    transcriptsUnchanged: replay.transcriptsUnchanged,
                    secondRunNoOp: replay.secondRunNoOp,
                    ordinaryExportOmitsContext: replay.ordinaryExportOmitsContext,
                    compactedExportRetainsContext: replay.compactedExportRetainsContext,
                    defaultModelMigrated: replay.defaultModelMigrated,
                    chatModelMigrated: replay.chatModelMigrated,
                    unsupportedVersionRejected: replay.unsupportedVersionRejected,
                    providerCatalogMigrated: replay.providerCatalogMigrated,
                    actionPoliciesMigrated: replay.actionPoliciesMigrated,
                    savedServicesMigrated: replay.savedServicesMigrated,
                    futureActionPoliciesPreserved: replay.futureActionPoliciesPreserved,
                    actionPolicyResolutionValid: replay.actionPolicyResolutionValid,
                    skillChecks: replay.skillChecks,
                    secretsIndexRenamed: replay.secretsIndexRenamed,
                    fixtureResults: replay.fixtureResults
                ))
            } catch {
                reply.failure(error.localizedDescription)
            }
        }
    }

}
#endif

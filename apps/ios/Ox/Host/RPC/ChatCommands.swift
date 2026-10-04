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
        reply.success(GetChatResult(data: ChatSnapshot(session)))
    }

    @MainActor
    static func handleOpenChat(
        _ command: SessionRequest,
        chatManager: ChatManager,
        reply: OxHostRPC.Reply
    ) {
        guard let rawID = command.sessionId.flatMap(UUID.init(uuidString:)) else {
            return reply.failure("provide a full chat UUID")
        }
        Task { @MainActor in
            do {
                let chat = try await chatManager.openForClient(rawID)
                Log.agent.info("OxHostRPC.chats.open id=\(reply.id) chat=\(chat.id)")
                reply.success(GetChatResult(data: ChatSnapshot(chat)))
            } catch { reply.failure(error.localizedDescription) }
        }
    }

    @MainActor
    static func handleRespondChat(
        _ command: RespondChatRequest,
        chatManager: ChatManager,
        reply: OxHostRPC.Reply
    ) {
        guard case .found(let chat?) = resolveSession(chatManager, command.sessionId),
              case .prompt(let prompt) = chat.interaction,
              UUID(uuidString: command.promptId) == prompt.id else {
            return reply.failure("pending prompt not found; inspect the chat before responding")
        }
        guard prompt.secretEntry == nil else {
            return reply.failure("enter credentials in Ox, not through chat responses")
        }
        guard !command.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.answer.count <= 2_000,
              prompt.allowsCustomAnswer || prompt.options.contains(command.answer) else {
            return reply.failure("provide one of the prompt options or an allowed custom answer")
        }
        chat.resolvePrompt(blockId: prompt.id, answer: command.answer)
        Log.agent.info("OxHostRPC.chats.respond id=\(reply.id) chat=\(chat.id) prompt=\(prompt.id)")
        reply.success(RespondChatResult(chatId: chat.id.uuidString, promptId: prompt.id.uuidString))
    }

    struct RespondChatResult: Encodable {
        let chatId: String
        let promptId: String
    }

    @MainActor
    static func handleNewChat(
        _ command: NewChatRequest,
        chatManager: ChatManager,
        reply: OxHostRPC.Reply
    ) {
        let selection: (client: any ProviderClient, model: ProviderModel)?
        switch (command.providerId, command.modelId) {
        case (nil, nil):
            selection = nil
        case (let providerId?, let modelId?):
            guard let client = ProviderRegistry.shared.client(id: providerId) else {
                return reply.failure("unknown provider: \(providerId)")
            }
            guard let model = client.models.first(where: { $0.id == modelId }) else {
                return reply.failure("unknown model: \(modelId) for provider \(providerId)")
            }
            selection = (client, model)
        default:
            return reply.failure("provide both providerId and modelId")
        }
        let chat = chatManager.startNewChat()
        if chat.isTemporary != (command.temporary ?? false) {
            chatManager.toggleTemporaryChat()
        }
        if let selection {
            chat.switchModel(
                to: selection.client,
                model: selection.model,
                selection: ModelSelection(
                    providerID: selection.client.id,
                    modelID: selection.model.id,
                    reasoningEffort: selection.model.selectedReasoningEffort
                )
            )
        }
        let model = "\(chat.modelSelection.providerID):\(chat.modelSelection.modelID)"
        Log.agent.info("OxHostRPC.chats.new id=\(reply.id) chat=\(chat.id) temporary=\(chat.isTemporary) model=\(model)")
        reply.success(NewChatResult(chatId: chat.id.uuidString, temporary: chat.isTemporary, model: model))
    }

    @MainActor
    static func handleSendChat(
        _ command: SendChatRequest,
        chatManager: ChatManager,
        reply: OxHostRPC.Reply
    ) {
        guard !command.text.isEmpty else { return reply.failure("missing text") }
        let chat: Chat
        switch resolveSession(chatManager, command.sessionId) {
        case .error(let error): return reply.failure(error)
        case .found(nil): return reply.failure("no active chat; create one with chats.new")
        case .found(let resolved?): chat = resolved
        }
        let wait = command.wait ?? true
        Log.agent.info("OxHostRPC.chats.send id=\(reply.id) chat=\(chat.id) chars=\(command.text.count) wait=\(wait)")
        guard wait else {
            chat.enqueue(command.text)
            return reply.success(SendChatResult(chatId: chat.id.uuidString, outcome: "queued"))
        }
        Task { @MainActor in
            let outcome = await chat.submitUntilAttention(command.text)
            Log.agent.info("OxHostRPC.chats.send id=\(reply.id) chat=\(chat.id) outcome=\(outcome.logLabel)")
            reply.success(SendChatResult(chatId: chat.id.uuidString, outcome: outcome))
        }
    }

    @MainActor
    static func handleStopChat(
        _ command: SessionRequest,
        chatManager: ChatManager,
        reply: OxHostRPC.Reply
    ) {
        let chat: Chat
        switch resolveSession(chatManager, command.sessionId) {
        case .error(let error): return reply.failure(error)
        case .found(nil): return reply.failure("no active chat")
        case .found(let resolved?): chat = resolved
        }
        let wasRunning = chat.isBusy
        chat.stopCurrentTurn()
        Log.agent.info("OxHostRPC.chats.stop id=\(reply.id) chat=\(chat.id) wasRunning=\(wasRunning)")
        reply.success(StopChatResult(chatId: chat.id.uuidString, wasRunning: wasRunning))
    }

    struct NewChatResult: Encodable {
        let chatId: String
        let temporary: Bool
        let model: String
    }

    struct SendChatResult: Encodable {
        let chatId: String
        let outcome: String
        var text: String?
        var error: String?

        init(chatId: String, outcome: String) {
            self.chatId = chatId
            self.outcome = outcome
        }

        init(chatId: String, outcome: ChatSubmissionOutcome) {
            self.init(chatId: chatId, outcome: outcome.logLabel)
            switch outcome {
            case .completed(let response): text = response
            case .failed(let message): error = message
            case .cancelled, .needsAttention: break
            }
        }
    }

    struct StopChatResult: Encodable {
        let chatId: String
        let wasRunning: Bool
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
        let data: ChatSnapshot?
    }

    @MainActor
    static func handleListProviders(_ command: EmptyRequest, reply: OxHostRPC.Reply) {
        let registry = ProviderRegistry.shared
        let providers = registry.clients.map { client in
            let diagnostics = client.protocolDiagnostics
            return ProviderRow(
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
        Log.agent.debug("OxHostRPC.providers.list id=\(reply.id) count=\(providers.count)")
        reply.success(ListProvidersResult(region: AppRegion.shared.region.rawValue, providers: providers))
    }

    @MainActor
    static func handleGetLogs(_ command: GetLogsRequest, reply: OxHostRPC.Reply) {
        Task {
            do {
                let limit = command.limit ?? 2_000
                guard (1...2_000).contains(limit),
                      command.cursor.map({ !$0.isEmpty && $0.count <= 2_048 }) ?? true else {
                    reply.failure("logs.list: limit must be 1...2000 and cursor must be a nonempty token.", code: -32602)
                    return
                }
                let fields: [String: String?] = ["level": command.level, "category": command.category,
                                                "query": command.query, "since": command.since]
                let query = try AppLogQuery(options: .object(fields.compactMapValues { $0.map(JSONValue.string) }))
                let page = try await LogFile.shared.page(limit: limit, cursor: command.cursor, level: query.level,
                                                         category: query.category, query: query.query, since: query.since)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let logs = page.entries.map {
                    DebugLogRow(
                        seq: $0.id,
                        time: formatter.string(from: $0.date),
                        level: $0.level.name,
                        category: $0.category,
                        thread: $0.thread,
                        location: $0.location,
                        message: $0.message
                    )
                }
                reply.success(GetLogsResult(logs: logs, nextCursor: page.nextCursor, hasMore: page.nextCursor != nil))
            } catch {
                reply.failure(error.localizedDescription)
            }
        }
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
                    retiredGemmaRemoved: replay.retiredGemmaRemoved,
                    fixtureResults: replay.fixtureResults
                ))
            } catch {
                reply.failure(error.localizedDescription)
            }
        }
    }

}

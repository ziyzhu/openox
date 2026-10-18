import Foundation

extension OxHostProtocol {
    @MainActor
    static func handleListConversations(
        _ command: EmptyRequest,
        host: any OxHost,
        reply: OxHostRPC.Reply
    ) {
        Task { @MainActor in
            let conversations = conversationRows(await host.listConversations())
            Log.agent.debug("OxHostRPC.chats.list id=\(reply.id) count=\(conversations.count)")
            reply.success(ListConversationsResult(conversations: conversations))
        }
    }

    @MainActor
    static func handleGetConversation(
        _ command: SessionRequest,
        conversationManager: ConversationManager,
        reply: OxHostRPC.Reply
    ) {
        Task { @MainActor in
            do {
                let session: Conversation?
                if let rawID = command.sessionId.flatMap(UUID.init(uuidString:)) {
                    session = try await conversationManager.loadForClient(rawID)
                } else {
                    switch resolveSession(conversationManager, command.sessionId) {
                    case .found(let resolved): session = resolved
                    case .error(let error):
                        reply.failure(error)
                        return
                    }
                }
                guard let session else {
                    reply.success(GetConversationResult(data: nil))
                    return
                }
                Log.agent.debug("OxHostRPC.chats.get id=\(reply.id) session=\(session.id)")
                reply.success(GetConversationResult(data: try await ConversationSnapshot(session)))
            } catch { reply.failure(error.localizedDescription) }
        }
    }

    @MainActor
    static func handleOpenConversation(
        _ command: SessionRequest,
        conversationManager: ConversationManager,
        reply: OxHostRPC.Reply
    ) {
        guard let rawID = command.sessionId.flatMap(UUID.init(uuidString:)) else {
            return reply.failure("provide a full conversation UUID")
        }
        Task { @MainActor in
            do {
                let conversation = try await conversationManager.openForClient(rawID)
                Log.agent.info("OxHostRPC.chats.open id=\(reply.id) conversation=\(conversation.id)")
                reply.success(GetConversationResult(data: try await ConversationSnapshot(conversation)))
            } catch { reply.failure(error.localizedDescription) }
        }
    }

    @MainActor
    static func handleRespondConversation(
        _ command: RespondConversationRequest,
        host: any OxHost,
        reply: OxHostRPC.Reply
    ) {
        Task { @MainActor in
            do {
                guard let promptID = UUID(uuidString: command.promptId) else {
                    throw HostConversationControlError.stalePrompt
                }
                let id = try resolveClientConversationID(host.conversations, command.sessionId,
                                                       missing: HostConversationControlError.stalePrompt.localizedDescription)
                Log.agent.info("OxHostRPC.chats.respond id=\(reply.id) conversation=\(id) prompt=\(promptID)")
                let controller = EmbeddedHostConversationController(host: host)
                let conversationID = try await controller.respondToPrompt(promptID, in: id, answer: command.answer)
                reply.success(RespondConversationResult(chatId: conversationID.uuidString, promptId: promptID.uuidString))
            } catch { reply.failure(error.localizedDescription) }
        }
    }

    struct RespondConversationResult: Encodable {
        let chatId: String
        let promptId: String
    }

    @MainActor
    static func handleNewConversation(
        _ command: NewConversationRequest,
        conversationManager: ConversationManager,
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
        var conversation = conversationManager.startNewConversation()
        if conversation.isTemporary != (command.temporary ?? false) {
            conversationManager.toggleTemporaryConversation()
            guard let current = conversationManager.current, current.isTemporary == (command.temporary ?? false) else {
                return reply.failure("could not create the requested conversation mode")
            }
            conversation = current
        }
        if let selection {
            conversation.switchModel(
                to: selection.client,
                model: selection.model,
                selection: ModelSelection(
                    providerID: selection.client.id,
                    modelID: selection.model.id,
                    reasoningEffort: selection.model.selectedReasoningEffort
                )
            )
        }
        let model = "\(conversation.modelSelection.providerID):\(conversation.modelSelection.modelID)"
        Log.agent.info("OxHostRPC.chats.new id=\(reply.id) conversation=\(conversation.id) temporary=\(conversation.isTemporary) model=\(model)")
        reply.success(NewConversationResult(chatId: conversation.id.uuidString, temporary: conversation.isTemporary, model: model))
    }

    @MainActor
    static func handleSendConversation(
        _ command: SendConversationRequest,
        host: any OxHost,
        reply: OxHostRPC.Reply
    ) {
        guard !command.text.isEmpty else { return reply.failure("missing text") }
        Task { @MainActor in
            do {
                let id = try resolveClientConversationID(host.conversations, command.sessionId,
                                                       missing: "no active conversation; create one with conversations.new")
                Log.agent.info("OxHostRPC.chats.send id=\(reply.id) conversation=\(id) chars=\(command.text.count) wait=\(command.wait ?? true)")
                let controller = EmbeddedHostConversationController(host: host)
                let result = try await controller.sendText(command.text, to: id,
                                                           mode: command.wait == false ? .enqueue : .untilAttention)
                reply.success(SendConversationResult(result))
            } catch { reply.failure(error.localizedDescription) }
        }
    }

    @MainActor
    static func handleStopConversation(
        _ command: SessionRequest,
        host: any OxHost,
        reply: OxHostRPC.Reply
    ) {
        Task { @MainActor in
            do {
                let id = try resolveClientConversationID(host.conversations, command.sessionId, missing: "no active conversation")
                Log.agent.info("OxHostRPC.chats.stop id=\(reply.id) conversation=\(id)")
                let result = try await EmbeddedHostConversationController(host: host).stopConversation(id)
                reply.success(StopConversationResult(chatId: result.conversationID.uuidString, wasRunning: result.wasRunning))
            } catch { reply.failure(error.localizedDescription) }
        }
    }

    struct NewConversationResult: Encodable {
        let chatId: String
        let temporary: Bool
        let model: String
    }

    struct SendConversationResult: Encodable {
        let chatId: String
        let outcome: String
        var text: String?
        var error: String?

        init(chatId: String, outcome: String) {
            self.chatId = chatId
            self.outcome = outcome
        }

        init(_ result: HostConversationSendResult) {
            switch result.outcome {
            case .queued: self.init(chatId: result.conversationID.uuidString, outcome: "queued")
            case .observed(let outcome): self.init(chatId: result.conversationID.uuidString, outcome: outcome)
            }
        }

        init(chatId: String, outcome: ConversationSubmissionOutcome) {
            self.init(chatId: chatId, outcome: outcome.logLabel)
            switch outcome {
            case .completed(let response): text = response
            case .failed(let message): error = message
            case .cancelled, .needsAttention: break
            }
        }
    }

    struct StopConversationResult: Encodable {
        let chatId: String
        let wasRunning: Bool
    }

    enum ConversationLookup {
        case found(Conversation?)
        case error(String)
    }

    @MainActor
    static func resolveSession(_ manager: ConversationManager, _ sessionId: String?) -> ConversationLookup {
        guard let sessionId, !sessionId.isEmpty else { return .found(manager.current) }
        if let session = manager.debugSession(matching: sessionId) {
            return .found(session)
        }
        return .error("unknown conversation: \(sessionId)")
    }

    @MainActor
    static func resolveClientConversationID(_ manager: ConversationManager, _ sessionId: String?, missing: String) throws -> UUID {
        if let id = sessionId.flatMap(UUID.init(uuidString:)) { return id }
        switch resolveSession(manager, sessionId) {
        case .found(let conversation?): return conversation.id
        case .found(nil): throw RuntimeError.bridge(missing)
        case .error(let error): throw RuntimeError.bridge(error)
        }
    }

    struct GetConversationResult: Encodable {
        let data: ConversationSnapshot?
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
        conversationManager: ConversationManager,
        reply: OxHostRPC.Reply
    ) {
        guard command.domain == "save", let entered = conversationManager.debugControlRepositorySaveGate(command.action) else {
            reply.failure("expected hold, release, or status for save")
            return
        }
        reply.success(RepositorySaveGateResult(entered: entered))
    }

}

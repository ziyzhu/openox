#if targetEnvironment(simulator)
import Foundation

extension OxHostProtocol {
    @MainActor
    static func handleGetLatestResponse(
        _ command: IDRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        Task { @MainActor in
            let response = await chatManager.latestCompletedResponse()
            reply(encode(GetLatestResponseResult(
                id: command.id,
                ok: true,
                response: response
            )))
        }
    }

    @MainActor
    static func handleRunDeadlineChat(
        _ command: RunDeadlineChatRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard let chat = chatManager.current, !chat.isBusy else {
            reply(encode(RunDeadlineChatResult(
                id: command.id,
                ok: false,
                outcome: "unavailable",
                busy: chatManager.current?.isBusy == true,
                prompts: [],
                elapsedMilliseconds: 0,
                error: "idle chat unavailable"
            )))
            return
        }
        Task { @MainActor in
            let budget = OxIntentBudget(
                responseWindow: .milliseconds(max(0, command.delayMilliseconds))
            )
            try? await Task.sleep(
                for: .milliseconds(max(0, command.setupDelayMilliseconds ?? 0))
            )
            let interaction = command.answers.map {
                DeadlineChatInteraction(
                    answers: $0,
                    delayMilliseconds: command.answerDelayMilliseconds ?? 0
                )
            }
            let completion = if let interaction {
                await OxIntentSupport.waitForCompletion(
                    budget: budget,
                    chat: { chat },
                    interaction: { try await interaction.respond(to: $0) }
                ) {
                    await chat.submitAndWait(command.prompt, replyStyle: .spokenBrief)
                }
            } else {
                await OxIntentSupport.waitForCompletion(
                    budget: budget
                ) {
                    await chat.submitAndWait(command.prompt, replyStyle: .spokenBrief)
                }
            }
            reply(encode(RunDeadlineChatResult(
                id: command.id,
                ok: true,
                outcome: completion.logLabel,
                busy: chat.isBusy,
                prompts: interaction?.prompts ?? [],
                elapsedMilliseconds: budget.elapsedMilliseconds,
                error: nil
            )))
        }
    }

    @MainActor

    static func handleListChats(
        _ command: IDRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        let currentId = chatManager.currentId
        let chats = chatManager.orderedSummaries.map { summary in
            ChatRow(
                id: summary.id.uuidString,
                title: summary.displayTitle,
                model: summary.modelID.map(JSONValue.string) ?? .null,
                createdAt: iso(summary.createdAt),
                lastActivity: summary.lastActivity.map { .string(iso($0)) } ?? .null,
                active: summary.id == currentId
            )
        }
        Log.agent.debug("OxHostProtocol.list-chats id=\(command.id) count=\(chats.count)")
        reply(encode(ListChatsResult(id: command.id, ok: true, chats: chats, error: nil)))
    }

    @MainActor
    static func handleGetChat(
        _ command: SessionRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        let session: Chat?
        switch resolveSession(chatManager, command.sessionId) {
        case .found(let s): session = s
        case .error(let error):
            reply(encode(GetChatResult(id: command.id, ok: false, data: nil, error: error)))
            return
        }
        guard let session else {
            reply(encode(GetChatResult(id: command.id, ok: true, data: nil, error: nil)))
            return
        }
        Log.agent.debug("OxHostProtocol.get-chat id=\(command.id) session=\(session.id)")
        reply(encode(GetChatResult(id: command.id, ok: true, data: DebugSnapshot(session), error: nil)))
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
        let kind = "get-chat-result"
        let id: String
        let ok: Bool
        let data: DebugSnapshot?
        let error: String?
    }

    @MainActor
    static func handleListModels(_ command: IDRequest, reply: @escaping @MainActor (Data) -> Void) {
        let registry = LLMRegistry.shared
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
                        selectedReasoningEffort: registry.reasoningEffort(for: $0, in: client.id),
                        inputModalities: $0.modalities.input.map(\.rawValue).sorted(),
                        outputModalities: $0.modalities.output.map(\.rawValue).sorted(),
                        wireProtocol: client.wireProtocol(for: $0)?.rawValue
                    )
                }
            )
        }
        Log.agent.debug("OxHostProtocol.list-models id=\(command.id) count=\(clients.count)")
        reply(encode(ListModelsResult(id: command.id, region: AppRegion.shared.region.rawValue, clients: clients)))
    }

    @MainActor
    static func handleGetLogs(_ command: IDRequest, reply: @escaping @MainActor (Data) -> Void) {
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
        reply(encode(GetLogsResult(id: command.id, logs: logs)))
    }

    @MainActor
    static func handleRepositorySaveGate(
        _ command: RepositoryGateRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard command.domain == "save", let entered = chatManager.debugControlRepositorySaveGate(command.action) else {
            reply(encode(RepositorySaveGateResult(id: command.id, ok: false, entered: nil, error: "expected hold, release, or status for save")))
            return
        }
        reply(encode(RepositorySaveGateResult(id: command.id, ok: true, entered: entered, error: nil)))
    }

    @MainActor
    static func handleReplayReducer(_ command: ReplayReducerRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard !command.fixtures.isEmpty else {
            reply(encode(ReducerReplayResult(
                id: command.id,
                ok: false,
                fixtures: nil,
                error: "No reducer fixtures were provided."
            )))
            return
        }
        let results = command.fixtures.map { fixture in
            let state = ChatDocument.replaying(fixture.turns)
            let projection = state.blocksWithTurn()
            let sources = state.projection.compactMap { block -> ReducerBlockSource? in
                guard let turn = state.sourceTurnIDs[RenderBlockID(block.id)] else { return nil }
                return ReducerBlockSource(blockID: block.id.uuidString, turnID: turn.rawValue.uuidString)
            }
            return ReducerReplayFixture(
                name: fixture.name,
                snapshot: ReducerReplaySnapshot(
                    turns: state.turns,
                    blocks: state.projection,
                    blockTurns: projection.map(\.1),
                    blockSources: sources,
                    wireMessages: state.toWire()
                )
            )
        }
        reply(encode(ReducerReplayResult(
            id: command.id,
            ok: true,
            fixtures: results,
            error: nil
        )))
    }

}
#endif

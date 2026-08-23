#if targetEnvironment(simulator)
import Foundation

extension DebugCommandRouter {
    @MainActor
    static func handleGetLatestResponse(
        _ command: IDRequest,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        Task { @MainActor in
            let response = await chatManager?.latestCompletedResponse()
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
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard let chat = chatManager?.current, !chat.isBusy else {
            reply(encode(RunDeadlineChatResult(
                id: command.id,
                ok: false,
                outcome: "unavailable",
                busy: chatManager?.current?.isBusy == true,
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

    static func handleListChats(_ command: IDRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard let manager = chatManager else {
            reply(encode(ListChatsResult(id: command.id, ok: false, chats: nil, error: "session manager unavailable")))
            return
        }
        let currentId = manager.currentId
        let chats = manager.orderedSummaries.map { summary in
            ChatRow(
                id: summary.id.uuidString,
                title: summary.displayTitle,
                model: summary.modelID.map(JSONValue.string) ?? .null,
                createdAt: iso(summary.createdAt),
                lastActivity: summary.lastActivity.map { .string(iso($0)) } ?? .null,
                active: summary.id == currentId
            )
        }
        Log.agent.debug("DebugCommandRouter.list-chats id=\(command.id) count=\(chats.count)")
        reply(encode(ListChatsResult(id: command.id, ok: true, chats: chats, error: nil)))
    }

    @MainActor
    static func handleGetChat(_ command: SessionRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard let manager = chatManager else {
            reply(encode(GetChatResult(id: command.id, ok: false, data: nil, error: "session manager unavailable")))
            return
        }
        let session: Chat?
        switch resolveSession(manager, command.sessionId) {
        case .found(let s): session = s
        case .error(let error):
            reply(encode(GetChatResult(id: command.id, ok: false, data: nil, error: error)))
            return
        }
        guard let session else {
            reply(encode(GetChatResult(id: command.id, ok: true, data: nil, error: nil)))
            return
        }
        Log.agent.debug("DebugCommandRouter.get-chat id=\(command.id) session=\(session.id)")
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
        let clients = LLMRegistry.shared.clients.map { client in
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
                        selectedReasoningEffort: $0.lowestReasoningEffort,
                        inputModalities: $0.modalities.input.map(\.rawValue).sorted(),
                        outputModalities: $0.modalities.output.map(\.rawValue).sorted(),
                        wireProtocol: client.wireProtocol(for: $0)?.rawValue
                    )
                }
            )
        }
        Log.agent.debug("DebugCommandRouter.list-models id=\(command.id) count=\(clients.count)")
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
    static func handleGetTranscript(_ command: IDRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard let viewportController else {
            reply(encode(GetTranscriptResult(id: command.id, ok: false, transcript: nil, error: "transcript unavailable")))
            return
        }
        reply(encode(GetTranscriptResult(id: command.id, ok: true, transcript: viewportController.debugSnapshot(), error: nil)))
    }

    @MainActor
    static func handleGetPerformance(_ command: IDRequest, reply: @escaping @MainActor (Data) -> Void) {
        Task { @MainActor in
            let snapshot = await DebugPerformance.snapshot()
            reply(encode(GetPerformanceResult(id: command.id, data: snapshot)))
        }
    }

    @MainActor
    static func handleGetTranscriptPerformance(
        _ command: IDRequest,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        reply(encode(TranscriptPerformanceResult(
            kind: "get-transcript-performance-result",
            id: command.id,
            ok: true,
            data: DebugTranscriptPerformance.snapshot(),
            error: nil
        )))
    }

    @MainActor
    static func handleOpenTranscriptFixture(
        _ command: TurnsRequest,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard let snapshot = chatManager?.debugOpenTranscriptFixture(turns: command.turns) else {
            reply(encode(TranscriptPerformanceResult(
                kind: "open-transcript-fixture-result",
                id: command.id,
                ok: false,
                data: nil,
                error: "expected 200 or 400 turns"
            )))
            return
        }
        reply(encode(TranscriptPerformanceResult(
            kind: "open-transcript-fixture-result",
            id: command.id,
            ok: true,
            data: snapshot,
            error: nil
        )))
    }

    @MainActor
    static func handleRetainBaselineSessions(_ command: CountRequest, reply: @escaping @MainActor (Data) -> Void) {
        let count = chatManager?.debugRetainBaselineSessions(count: max(0, command.count)) ?? 0
        reply(encode(RetainBaselineSessionsResult(id: command.id, count: count)))
    }

    @MainActor
    static func handleRepositorySaveGate(_ command: RepositoryGateRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard let manager = chatManager else {
            reply(encode(RepositorySaveGateResult(id: command.id, ok: false, entered: nil, error: "chat manager unavailable")))
            return
        }
        guard command.domain == "save", let entered = manager.debugControlRepositorySaveGate(command.action) else {
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

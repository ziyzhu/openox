import Foundation

extension Conversation {
    func loadOlderHistory() async {
        await loadHistory(userTurns: ConversationHistory.userTurnsPerPage)
    }

    func loadCompleteHistory() async throws {
        while let partial = history.partial {
            await loadHistory(userTurns: nil)
            if history.partial == partial { throw RuntimeError.bridge("Earlier messages in this conversation couldn't be loaded.") }
        }
    }

    func completeState() async throws -> ConversationState {
        try await loadCompleteHistory()
        return state
    }

    func privateDataContinuation() async -> ConversationContinuation? {
        guard (try? await loadCompleteHistory()) != nil else { return nil }
        return latestContinuation()
    }

    private func loadHistory(userTurns: Int?) async {
        switch history {
        case .complete:
            return
        case .loading(_, let task):
            await task.value
        case .partial(let partial):
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await fetchHistory(after: partial, userTurns: userTurns)
            }
            history = .loading(partial, task)
            await task.value
        }
    }

    private func fetchHistory(after partial: PartialHistory, userTurns: Int?) async {
        let startedAt = Date()
        let loaded = await repository.loadConversation(ConversationID(id), in: scope, history: .older(partial.older, userTurns: userTurns),
                                                       reserving: Set(turns.map(\.id)))
        guard let loaded else {
            history = .partial(partial)
            Log.session.error("Conversation.history unavailable id=\(id)")
            return
        }
        let older = await Self.prepare(loaded.state.turns, before: blockOrdinals.lowerBound)
        guard prependOlder(older) else {
            history = .partial(partial)
            Log.session.error("Conversation.history rejected id=\(id) blockOrdinals=\(blockOrdinals.lowerBound)..<\(blockOrdinals.upperBound)")
            return
        }
        storedTurns = storedTurns.map { loaded.state.turns + $0 }
        history = loaded.older.map { .partial(PartialHistory(older: $0, storedPreview: partial.storedPreview)) } ?? .complete
        Log.session.info("Conversation.history loaded id=\(id) page=\(userTurns.map(String.init) ?? "rest") turns=\(older.turns.count) blocks=\(older.blockCount) older=\(history.hasOlder) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))")
    }

    @concurrent
    private static func prepare(_ turns: [Turn], before ordinal: Int) async -> ConversationDocument {
        ConversationDocument.restoring(turns, before: ordinal)
    }
}

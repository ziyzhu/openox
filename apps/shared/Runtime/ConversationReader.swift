import Foundation

@MainActor
protocol ConversationReading {
    func listConversations() async throws -> [ConversationSummary]
    func readConversation(_ id: UUID) async throws -> ConversationReadState
}

struct ConversationReadState {
    let id: UUID
    let title: String
    let model: ModelSelection
    let blocks: [Block]
    let isBusy: Bool
    let pendingPrompt: PendingPrompt?

    struct PendingPrompt {
        let id: UUID
        let prompt: String
        let options: [String]
        let allowsCustomAnswer: Bool
        let requiresSecureEntry: Bool
    }

    @MainActor
    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.metadata.displayTitle
        model = conversation.modelSelection
        blocks = conversation.transcript
        isBusy = conversation.isBusy
        if case .prompt(let prompt) = conversation.interaction {
            pendingPrompt = PendingPrompt(
                id: prompt.id,
                prompt: prompt.prompt,
                options: prompt.options,
                allowsCustomAnswer: prompt.allowsCustomAnswer,
                requiresSecureEntry: prompt.secretEntry != nil
            )
        } else {
            pendingPrompt = nil
        }
    }
}

@MainActor
struct EmbeddedConversationReader: ConversationReading {
    private let runtime: any ProfileRuntime

    init(runtime: any ProfileRuntime) {
        self.runtime = runtime
    }

    func listConversations() async throws -> [ConversationSummary] {
        try await runtime.prepare()
        return await runtime.listConversations()
    }

    func readConversation(_ id: UUID) async throws -> ConversationReadState {
        try await runtime.prepare()
        let conversation = try await runtime.conversations.loadForClient(id)
        return ConversationReadState(conversation)
    }
}

import Foundation

@MainActor
protocol HostConversationReading {
    func listConversations() async throws -> [HostConversationSummary]
    func readConversation(_ id: UUID) async throws -> HostConversationState
}

struct HostConversationState {
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
struct EmbeddedHostConversationReader: HostConversationReading {
    private let host: any OxHost

    init(host: any OxHost) {
        self.host = host
    }

    func listConversations() async throws -> [HostConversationSummary] {
        try await host.prepare()
        return host.listConversations()
    }

    func readConversation(_ id: UUID) async throws -> HostConversationState {
        try await host.prepare()
        let conversation = try await host.conversations.loadForClient(id)
        return HostConversationState(conversation)
    }
}

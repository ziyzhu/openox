import Foundation

struct ConversationSnapshot: Encodable {
    let id: String
    let model: ProviderModel
    let systemPrompt: String
    let renderedSystemPrompt: String
    let soul: String
    let memory: String
    let tools: [ToolDecl]
    let messages: [Message]
    let blocks: [Block]
    let isBusy: Bool
    let pendingPrompt: PendingPrompt?

    struct PendingPrompt: Encodable {
        let id: String
        let prompt: String
        let options: [String]
        let allowsCustomAnswer: Bool
        let requiresApp: Bool

        init(_ prompt: Conversation.PendingPrompt) {
            id = prompt.id.uuidString
            self.prompt = prompt.prompt
            options = prompt.options
            allowsCustomAnswer = prompt.allowsCustomAnswer
            requiresApp = prompt.secretEntry != nil
        }
    }

    struct ToolDecl: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
        let strict: Bool

        init(_ tool: any AgentTool) {
            name = tool.name
            description = tool.description
            parameters = tool.parameters
            strict = tool.strict
        }
    }

    @MainActor
    init(_ conversation: Conversation) async throws {
        let configuration = conversation.preparedConfiguration ?? conversation.agentConfiguration(client: conversation.client, model: conversation.model)
        messages = try await conversation.canonicalMessages()
        id = conversation.id.uuidString
        model = configuration.model
        let prompt = try await conversation.renderPrompt(configuration: configuration)
        systemPrompt = prompt.scaffold
        renderedSystemPrompt = prompt.rendered
        soul = prompt.soul
        memory = prompt.memory
        tools = configuration.tools.map(ToolDecl.init)
        blocks = conversation.transcript
        isBusy = conversation.isBusy
        if case .prompt(let prompt) = conversation.interaction {
            pendingPrompt = PendingPrompt(prompt)
        } else {
            pendingPrompt = nil
        }
    }
}

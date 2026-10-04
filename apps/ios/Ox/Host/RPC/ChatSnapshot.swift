import Foundation

struct ChatSnapshot: Encodable {
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

        init(_ prompt: Chat.PendingPrompt) {
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
    init(_ chat: Chat) {
        let agent = chat.agentSnapshot
        id = chat.id.uuidString
        model = agent?.model ?? chat.model
        let currentMemory = chat.systemPromptMemory
        let userSkills = Skills.shared.all
        let breakdown = Chat.systemPromptBreakdown(
            memory: currentMemory,
            userSkills: userSkills
        )
        systemPrompt = breakdown.scaffold
        renderedSystemPrompt = agent?.systemPrompt ?? Chat.composeSystemPrompt(
            memory: currentMemory,
            userSkills: userSkills
        )
        soul = breakdown.soul
        memory = breakdown.memory
        tools = (agent?.tools ?? []).map(ToolDecl.init)
        messages = agent?.messages ?? []
        blocks = chat.transcript
        isBusy = chat.isBusy
        if case .prompt(let prompt) = chat.interaction {
            pendingPrompt = PendingPrompt(prompt)
        } else {
            pendingPrompt = nil
        }
    }
}

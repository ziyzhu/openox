import Foundation

struct DebugSnapshot: Encodable {
    let id: String
    let model: ProviderModel
    let systemPrompt: String
    let renderedSystemPrompt: String
    let soul: String
    let memory: String
    let tools: [ToolDecl]
    let messages: [Message]
    let blocks: [Block]

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
        let toolsAvailable = chat.client.supportsTools(for: chat.model)
        let currentMemory = UserMemory.shared.text
        let userSkills = Skills.shared.all
        let breakdown = Chat.systemPromptBreakdown(
            memory: currentMemory,
            userSkills: userSkills,
            toolsAvailable: toolsAvailable
        )
        systemPrompt = breakdown.scaffold
        renderedSystemPrompt = agent?.systemPrompt ?? Chat.composeSystemPrompt(
            memory: currentMemory,
            userSkills: userSkills,
            toolsAvailable: toolsAvailable
        )
        soul = breakdown.soul
        memory = breakdown.memory
        tools = (agent?.tools ?? []).map(ToolDecl.init)
        messages = agent?.messages ?? []
        blocks = chat.transcript
    }
}

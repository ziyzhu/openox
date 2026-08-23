import Foundation

nonisolated public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [Message]
    public var tools: [any AgentTool]

    public init(systemPrompt: String, messages: [Message], tools: [any AgentTool]) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

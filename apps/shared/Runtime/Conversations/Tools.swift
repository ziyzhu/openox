import Foundation

nonisolated struct ToolSchema: AgentTool {
    let name: String
    let description: String
    let parameters: JSONValue
    let strict: Bool

    init(name: String, description: String, parameters: JSONValue, strict: Bool = true) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }

    func execute(toolCallId: String, args: JSONValue) async throws -> ToolResult {
        ToolResult(text: "")
    }
}

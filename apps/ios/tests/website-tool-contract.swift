import Foundation

nonisolated enum LLMFailureKind: Sendable {
    case provider
    case unsupportedInput
}

nonisolated protocol ProviderClientError: Error {
    var message: String { get }
    var failureKind: LLMFailureKind { get }
}

nonisolated protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
}

nonisolated struct ToolCall: Sendable {
    let id: String
    let name: String
    let arguments: JSONValue
}

nonisolated struct TextContent: Sendable {
    let text: String
}

nonisolated enum ContentBlock: Sendable {
    case text(TextContent)
    case thinking
    case toolCall(ToolCall)
    case attachment
}

nonisolated struct UserMessage: Sendable {
    let content: [ContentBlock]
    let transientContext: String?
}

nonisolated struct AssistantMessage: Sendable {
    let content: [ContentBlock]
}

nonisolated struct ToolResultMessage: Sendable {
    let content: [ContentBlock]
    let toolName: String
    let toolCallId: String
    let isError: Bool
}

nonisolated enum Message: Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
}

nonisolated struct TestTool: AgentTool {
    let name = "execute"
    let description = "Run JavaScript"
    let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["code": .object(["type": .string("string")])]),
        "required": .array([.string("code")]),
        "additionalProperties": .bool(false),
    ])
}

@main
struct WebsiteToolContractChecks {
    static func main() throws {
        let tool = TestTool()
        let instructions = WebsiteToolContract.instructions([tool])
        precondition(instructions.contains("<tools>"))
        precondition(instructions.contains("\"type\":\"function\""))
        precondition(instructions.contains("<tool_call>"))
        precondition(WebsiteToolContract.isPossibleCallPrefix("<tool_ca"))
        precondition(!WebsiteToolContract.isPossibleCallPrefix("The answer is 56."))

        let valid = "<tool_call>\n{\"name\":\"execute\",\"arguments\":{\"code\":\"console.log(56)\"}}\n</tool_call>"
        let call = try WebsiteToolContract.call(from: valid, tools: [tool])
        precondition(call?.name == "execute")
        precondition(call?.arguments.objectValue?["code"] == .string("console.log(56)"))
        let embeddedTag = "<tool_call>{\"name\":\"execute\",\"arguments\":{\"code\":\"console.log('\\u003c/tool_call>')\"}}</tool_call>"
        let embeddedCall = try WebsiteToolContract.call(from: embeddedTag, tools: [tool])
        precondition(embeddedCall != nil)
        let ordinaryText = try WebsiteToolContract.call(from: "The answer is 56.", tools: [tool])
        precondition(ordinaryText == nil)

        for invalid in [
            "<tool_call>{\"name\":\"execute\",\"arguments\":{}}</tool_call>",
            "<tool_call>{\"name\":\"unknown\",\"arguments\":{\"code\":\"x\"}}</tool_call>",
            "<tool_call>{\"name\":\"execute\",\"arguments\":{\"code\":\"x\"},\"extra\":1}</tool_call>",
            "<tool_call>{\"name\":\"execute\",\"arguments\":{\"code\":\"x\"}}</tool_call> extra",
            "<tool_call>{\"name\":\"execute\",\"arguments\":{\"code\":\"x\"}}",
        ] {
            do {
                _ = try WebsiteToolContract.call(from: invalid, tools: [tool])
                preconditionFailure("Accepted invalid Action call")
            } catch is WebsiteProviderError {}
        }

        let response = WebsiteToolContract.response(name: "execute", callID: "web-1", isError: false, text: "56")
        precondition(response.hasPrefix("<tool_response>\n"))
        precondition(response.hasSuffix("\n</tool_response>"))
        let payload = String(response.dropFirst("<tool_response>\n".count).dropLast("\n</tool_response>".count))
        precondition(JSONValue.parse(jsonString: payload)?.objectValue?["content"] == .string("56"))

        let prompt = try WebsiteProviderPrompt.prompt(
            messages: [
                .user(UserMessage(content: [.text(TextContent(text: "Run it"))], transientContext: nil)),
                .assistant(AssistantMessage(content: [.toolCall(call!)])),
                .toolResult(ToolResultMessage(content: [.text(TextContent(text: "56"))], toolName: "execute", toolCallId: call!.id, isError: false)),
            ],
            toolInstructions: instructions,
            providerName: "Test"
        )
        let data = Data(prompt.utf8)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let turns = decoded["conversation"] as! [[String: String]]
        precondition(turns[1]["text"]?.hasPrefix("<tool_call>") == true)
        precondition(turns[2]["text"]?.hasPrefix("<tool_response>") == true)
        print("Website tool contract checks passed")
    }
}

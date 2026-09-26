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
    case attachment(Artifact)
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
    var transientAttachments: [TransientAttachment] = []
}

nonisolated struct Artifact: Sendable {
    enum Kind { case text, html, image, pdf, file }
    let fileURL: URL
    let displayName: String
    let mimeType: String
    let kind: Kind
    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    var size: Int? { try? Data(contentsOf: fileURL).count }
}

nonisolated struct TransientAttachment: Sendable {
    enum Kind { case text, image, pdf, file }
    let kind: Kind
    let mimeType: String
    let displayName: String
    let data: Data
}

nonisolated enum ArtifactLimits {
    static let fileBytes = 32 * 1024 * 1024
    static let textBytes = 200 * 1024
}

nonisolated enum PDFPreparer {
    static func prepareArtifact(_ data: Data) throws -> Data { data }
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
        precondition(instructions.contains("<ox_actions>"))
        precondition(instructions.contains("\"type\":\"function\""))
        precondition(instructions.contains("<ox_action_call>"))
        precondition(WebsiteToolContract.isPossibleCallPrefix("<ox_action_ca"))
        precondition(!WebsiteToolContract.isPossibleCallPrefix("The answer is 56."))

        let valid = "<ox_action_call>\n{\"name\":\"execute\",\"arguments\":{\"code\":\"console.log(56)\"}}\n</ox_action_call>"
        let call = try WebsiteToolContract.call(from: valid, tools: [tool])
        precondition(call?.name == "execute")
        precondition(call?.arguments.objectValue?["code"] == .string("console.log(56)"))
        let embeddedTag = "<ox_action_call>{\"name\":\"execute\",\"arguments\":{\"code\":\"console.log('\\u003c/ox_action_call>')\"}}</ox_action_call>"
        let embeddedCall = try WebsiteToolContract.call(from: embeddedTag, tools: [tool])
        precondition(embeddedCall != nil)
        let ordinaryText = try WebsiteToolContract.call(from: "The answer is 56.", tools: [tool])
        precondition(ordinaryText == nil)

        for invalid in [
            "<ox_action_call>{\"name\":\"execute\",\"arguments\":{}}</ox_action_call>",
            "<ox_action_call>{\"name\":\"unknown\",\"arguments\":{\"code\":\"x\"}}</ox_action_call>",
            "<ox_action_call>{\"name\":\"execute\",\"arguments\":{\"code\":\"x\"},\"extra\":1}</ox_action_call>",
            "<ox_action_call>{\"name\":\"execute\",\"arguments\":{\"code\":\"x\"}}</ox_action_call> extra",
            "<ox_action_call>{\"name\":\"execute\",\"arguments\":{\"code\":\"x\"}}",
        ] {
            do {
                _ = try WebsiteToolContract.call(from: invalid, tools: [tool])
                preconditionFailure("Accepted invalid Action call")
            } catch is WebsiteProviderError {}
        }

        let response = WebsiteToolContract.response(name: "execute", callID: "web-1", isError: false, text: "56")
        precondition(response.hasPrefix("<ox_action_result>\n"))
        precondition(response.hasSuffix("\n</ox_action_result>"))
        let payload = String(response.dropFirst("<ox_action_result>\n".count).dropLast("\n</ox_action_result>".count))
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
        precondition(turns[1]["text"]?.hasPrefix("<ox_action_call>") == true)
        precondition(turns[2]["text"]?.hasPrefix("<ox_action_result>") == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.png")
        let image = Data([1, 2, 3])
        try image.write(to: url)
        let artifact = Artifact(fileURL: url, displayName: "image.png", mimeType: "image/png", kind: .image)
        let result = ToolResultMessage(content: [.attachment(artifact)], toolName: "execute", toolCallId: "call-2", isError: false,
                                      transientAttachments: [
                                        .init(kind: .image, mimeType: "image/png", displayName: "image.png", data: image),
                                        .init(kind: .image, mimeType: "image/png", displayName: "image.png", data: Data([4, 5, 6])),
                                        .init(kind: .text, mimeType: "text/plain", displayName: "note.txt", data: Data("read me".utf8)),
                                      ])
        let media = try WebsiteProviderPrompt.prepare(messages: [
            .user(UserMessage(content: [.attachment(artifact)], transientContext: nil)),
            .toolResult(result),
            .user(UserMessage(content: [.text(TextContent(text: "Compare both images"))], transientContext: nil)),
        ], toolInstructions: instructions, providerName: "Test")
        precondition(media.attachments.count == 2)
        precondition(media.attachments.map(\.name) == ["ox-1-image.png", "ox-2-image.png"])
        precondition(media.attachments[1].data == Data([4, 5, 6]))
        precondition(!media.prompt.contains(image.base64EncodedString()))
        precondition(media.prompt.contains("read me"))
        precondition(media.prompt.contains("call-2"))
        precondition(media.prompt.components(separatedBy: "ox-1-image.png").count == 4)
        let attachmentOnly = try WebsiteProviderPrompt.prepare(messages: [.user(UserMessage(content: [.attachment(artifact)], transientContext: nil))],
                                                               toolInstructions: "", providerName: "Test")
        precondition(attachmentOnly.attachments.count == 1)
        try FileManager.default.removeItem(at: url)
        do {
            _ = try WebsiteProviderPrompt.prepare(messages: [.user(UserMessage(content: [.attachment(artifact)], transientContext: nil))], toolInstructions: "", providerName: "Test")
            preconditionFailure("Silently dropped a missing attachment")
        } catch is WebsiteProviderError {}
        print("Website tool contract checks passed")
    }
}

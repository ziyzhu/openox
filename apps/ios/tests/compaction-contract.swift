import Foundation

nonisolated public enum LLMFailureKind: String, Codable, Sendable {
    case provider
    case contextOverflow
}

nonisolated public struct Artifact: Codable, Equatable, Sendable {
    let fileName: String
    let mimeType: String
}

@main
struct CompactionContractChecks {
    static func main() {
        checkTranscript()
        checkOverflow()
        print("compaction contract checks passed")
    }

    static func checkTranscript() {
        let longOutput = String(repeating: "x", count: CompactionTranscript.toolResultCharacterLimit + 500)
        var assistant = AssistantMessage(model: "m", content: [
            .thinking(ThinkingContent("plan")),
            .text(TextContent("Running it.")),
            .toolCall(ToolCall(id: "c1", name: "execute", arguments: .object(["source": .string("run()")]))),
        ])
        assistant.stopReason = .toolUse
        let transcript = CompactionTranscript.render([
            .user(UserMessage(
                text: "Open the report",
                attachments: [Artifact(fileName: "report.pdf", mimeType: "application/pdf")],
                transientContext: "Location: Paris"
            )),
            .assistant(assistant),
            .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "execute", content: [.text(TextContent(longOutput))], isError: false)),
            .toolResult(ToolResultMessage(toolCallId: "c2", toolName: "execute", content: [.text(TextContent("boom"))], isError: true)),
            .assistant(AssistantMessage(model: "m", content: [])),
        ])
        precondition(transcript.hasPrefix("[User]: Location: Paris\nOpen the report\nAttached artifact: "))
        precondition(transcript.contains("\"filename\":\"report.pdf\""))
        precondition(transcript.contains("[Assistant thinking]: plan"))
        precondition(transcript.contains("[Assistant]: Running it."))
        precondition(transcript.contains("[Assistant tool calls]: execute({\"source\":\"run()\"})"))
        precondition(transcript.contains("[... 500 more characters truncated]"))
        precondition(!transcript.contains(longOutput))
        precondition(transcript.hasSuffix("[Tool error]: boom"))
        precondition(CompactionTranscript.truncated("short", limit: 10) == "short")
    }

    static func checkOverflow() {
        func response(_ stop: StopReason, input: Int, output: Int) -> AssistantMessage {
            var message = AssistantMessage(model: "m")
            message.stopReason = stop
            message.usage.input = input
            message.usage.output = output
            return message
        }
        let window = 200_000
        let requested = 32_000
        func overflow(_ message: AssistantMessage) -> Bool {
            isContextOverflow(message, contextWindow: window, requestedOutput: requested)
        }
        precondition(overflow(response(.length, input: 190_000, output: 9_000)))
        precondition(overflow(response(.length, input: 198_500, output: 0)))
        precondition(!overflow(response(.length, input: 50_000, output: 8_000)))
        precondition(!overflow(response(.length, input: 190_000, output: requested)))
        precondition(!overflow(response(.length, input: 0, output: 0)))
        precondition(!overflow(response(.stop, input: 190_000, output: 9_000)))
        precondition(overflow(response(.stop, input: 210_000, output: 10)))
        var classified = response(.error, input: 0, output: 0)
        classified.failureKind = .contextOverflow
        precondition(overflow(classified))
    }
}

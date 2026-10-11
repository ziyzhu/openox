import Foundation

nonisolated struct ToolExchangeAdapter: ModelAdapter {
    let id = "tool-exchange"

    func transform(messages: [Message], model _: ProviderModel) async -> ModelAdapterOutcome {
        var transformed: [Message] = []
        var pendingCalls: [ToolCall] = []
        var pendingTimestamp = Date.distantPast
        var repairedNames: [String] = []

        func flushPending() {
            guard !pendingCalls.isEmpty else { return }
            for call in pendingCalls {
                transformed.append(.toolResult(ToolResultMessage(
                    toolCallId: call.id,
                    providerCallID: call.providerCallID,
                    toolName: call.name,
                    content: [.text(TextContent("No result provided"))],
                    isError: true,
                    timestamp: pendingTimestamp
                )))
                repairedNames.append(call.name)
            }
            pendingCalls = []
        }

        for message in messages {
            switch message {
            case .assistant(let assistant):
                flushPending()
                transformed.append(message)
                pendingCalls = assistant.content.compactMap { block in
                    if case .toolCall(let call) = block { return call }
                    return nil
                }
                pendingTimestamp = assistant.timestamp
            case .toolResult(let result):
                transformed.append(message)
                pendingCalls.removeAll { $0.id == result.toolCallId }
            case .user:
                flushPending()
                transformed.append(message)
            }
        }
        flushPending()

        guard !repairedNames.isEmpty else { return .unchanged }
        Log.agent.warning("ToolExchangeAdapter repaired count=\(repairedNames.count) tools=[\(repairedNames.joined(separator: ","))]")
        return .transformed(transformed)
    }
}

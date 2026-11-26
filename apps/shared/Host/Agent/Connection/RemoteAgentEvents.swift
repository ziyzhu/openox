import Foundation

nonisolated struct RemoteAgentEvents {
    nonisolated enum Progress: Equatable {
        case running
        case settled(aborted: Bool)
    }

    let scope: ProfileScope
    private(set) var model: String
    private(set) var lastAssistant: AssistantMessage?
    private var stream = AssistantPartial()
    private var assistant: AssistantMessage?
    private var results: [ToolResultMessage] = []
    private var calls: [String: ToolCall] = [:]

    init(scope: ProfileScope, model: String) {
        self.scope = scope
        self.model = model
    }

    mutating func receive(_ event: JSONValue) -> (events: [AgentEvent], progress: Progress) {
        guard let fields = event.objectValue, let type = fields["type"]?.stringValue else { return ([], .running) }
        switch type {
        case "agent_start":
            return ([.runStarted(turnID: nil)], .running)
        case "turn_start":
            assistant = nil
            results = []
            stream.reset()
            return ([.generationStarted(model: model, turnID: nil)], .running)
        case "message_start":
            guard case .assistant(let message)? = fields["message"].flatMap(decodeMessage) else { return ([], .running) }
            if message.model != "unknown" { model = message.model }
            stream.message = message
            return ([.messageStart(.assistant(message))] + stream.reasoningEvents(message, completed: false)
                + [.messageUpdate(message, event: .start(partial: message))], .running)
        case "message_update":
            return (update(fields["assistantMessageEvent"]?.objectValue ?? [:]), .running)
        case "message_end":
            guard case .assistant(let message)? = fields["message"].flatMap(decodeMessage) else { return ([], .running) }
            assistant = message
            lastAssistant = message
            stream.message = nil
            for block in message.content { if case .toolCall(let call) = block { calls[call.id] = call } }
            return (stream.reasoningEvents(message, completed: true) + [.messageEnd(.assistant(message))], .running)
        case "tool_execution_start":
            let id = fields["toolCallId"]?.stringValue ?? ""
            let call = calls[id] ?? ToolCall(id: id, name: fields["toolName"]?.stringValue ?? "", arguments: fields["args"] ?? .object([:]))
            calls[id] = call
            return ([.toolExecutionStart(toolCall: call)], .running)
        case "tool_execution_end":
            guard let id = fields["toolCallId"]?.stringValue, let call = calls.removeValue(forKey: id) else { return ([], .running) }
            let result = toolResult(call, fields)
            results.append(result)
            return ([.toolExecutionEnd(toolCall: call, result: result)], .running)
        case "turn_end":
            guard let assistant else { return ([], .running) }
            return ([.generationFinished(message: assistant, toolResults: results)], .running)
        case "compaction_end":
            let result = fields["result"]?.objectValue ?? [:]
            return ([.compacted(beforeMessages: 0, afterMessages: 0, summaryChars: result["summary"]?.stringValue?.count ?? 0,
                                tokensBefore: result["tokensBefore"]?.intValue ?? 0)], .running)
        case "agent_settled":
            return ([], .settled(aborted: fields["aborted"]?.boolValue == true))
        default:
            return ([], .running)
        }
    }

    private mutating func update(_ change: [String: JSONValue]) -> [AgentEvent] {
        guard var message = stream.message, let index = change["contentIndex"]?.intValue else { return [] }
        switch change["type"]?.stringValue {
        case "text_start":
            place(.text(TextContent("")), at: index, in: &message)
        case "thinking_start":
            place(.thinking(ThinkingContent("")), at: index, in: &message)
        case "toolcall_start":
            place(.toolCall(ToolCall(id: change["id"]?.stringValue ?? "", name: change["toolName"]?.stringValue ?? "", arguments: .object([:]))), at: index, in: &message)
        case "toolcall_end":
            guard let value = change["toolCall"], let call = try? DurableMessageCodec.decodeToolCall(value, scope: scope) else { return [] }
            place(.toolCall(call), at: index, in: &message)
            stream.message = message
            return [.messageUpdate(message, event: .toolCallEnd(index: index, toolCall: call, partial: message))]
        case "text_delta", "thinking_delta":
            let updates = stream.applyDeltas([.object(change)])
            guard let partial = stream.message else { return [] }
            return stream.reasoningEvents(partial, completed: false) + updates.map { .messageUpdate(partial, event: $0) }
        default:
            return []
        }
        stream.message = message
        return [.messageUpdate(message, event: .start(partial: message))]
    }

    private func place(_ block: ContentBlock, at index: Int, in message: inout AssistantMessage) {
        if message.content.indices.contains(index) { message.content[index] = block }
        else if index == message.content.count { message.content.append(block) }
    }

    private func toolResult(_ call: ToolCall, _ fields: [String: JSONValue]) -> ToolResultMessage {
        let result = fields["result"]?.objectValue ?? [:]
        let value: JSONValue = .object([
            "role": .string("toolResult"), "toolCallId": .string(call.id), "toolName": .string(call.name),
            "content": result["content"] ?? .array([]), "isError": .bool(fields["isError"]?.boolValue == true),
            "timestamp": .double(Date().timeIntervalSince1970 * 1000),
        ])
        if case .toolResult(let message)? = decodeMessage(value) { return message }
        return ToolResultMessage(toolCallId: call.id, toolName: call.name, content: [], isError: true, timestamp: Date())
    }

    func decodeMessage(_ value: JSONValue) -> Message? {
        do { return try DurableMessageCodec.decode(Self.portable(value), scope: scope) }
        catch {
            Log.agent.debug("RemoteAgentEvents.message skipped error=\(error.localizedDescription)")
            return nil
        }
    }

    static func portable(_ value: JSONValue) -> JSONValue {
        guard var fields = value.objectValue else { return value }
        fields.removeValue(forKey: "details")
        if let content = fields["content"]?.arrayValue {
            fields["content"] = .array(content.compactMap { block in
                switch block.objectValue?["type"]?.stringValue {
                case "text", "thinking", "toolCall": block
                case "image": .object(["type": .string("text"), "text": .string("[image]")])
                default: nil
                }
            })
        }
        return .object(fields)
    }
}

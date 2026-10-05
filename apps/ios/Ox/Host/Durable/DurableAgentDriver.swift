import Foundation

/// Native capability adapter. The only agent loop on this path is Pi's committed task scheduler.
actor DurableAgentHost {
    typealias EventSink = @Sendable (AgentEvent) async -> Void
    private struct Binding {
        let scope: ProfileScope
        let configuration: AgentConfiguration
        let emit: EventSink
        let runtimeProfileID: String?
        let artifactScope: ProfileScope?
        var conversationID: Int?
        var assistant: AssistantMessage?
        var calls: [String: ToolCall] = [:]
    }
    private var bindings: [String: Binding] = [:]
    func bind(chatID: String, scope: ProfileScope, configuration: AgentConfiguration, runtimeProfileID: String? = nil, artifactScope: ProfileScope? = nil, emit: @escaping EventSink) {
        let previous = bindings[chatID]
        bindings[chatID] = Binding(scope: scope, configuration: configuration, emit: emit, runtimeProfileID: runtimeProfileID, artifactScope: artifactScope,
                                   conversationID: previous?.runtimeProfileID == runtimeProfileID ? previous?.conversationID : nil)
    }
    func expectReference(chatID: String, reference: JSONValue) throws {
        guard let binding = bindings[chatID], let fields = reference.objectValue,
              let profileID = fields["profileID"]?.stringValue, let conversationID = fields["conversationID"]?.intValue,
              conversationID >= 0, binding.runtimeProfileID == nil || binding.runtimeProfileID == profileID,
              binding.conversationID == nil || binding.conversationID == conversationID else {
            throw RuntimeError.bridge("Native conversation reference does not match its immutable route")
        }
        bindings[chatID]?.conversationID = conversationID
    }
    func unbind(chatID: String) { bindings.removeValue(forKey: chatID) }
    func failure(chatID: String) -> (String, LLMFailureKind?)? {
        guard let assistant = bindings[chatID]?.assistant else { return nil }
        if assistant.stopReason == .aborted { return ("aborted", nil) }
        return assistant.errorMessage.map { ($0, assistant.failureKind) }
    }

    func handle(_ method: String, _ params: JSONValue, stream: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue {
        guard let fields = params.objectValue, let chatID = fields["chatID"]?.stringValue,
              let binding = bindings[chatID] else { throw RuntimeError.bridge("Native conversation is not attached") }
        if method != "agentEvents", StorageRoot.currentScope != binding.scope {
            throw RuntimeError.bridge("Native capability belongs to a stale Profile scope; reacquire its runtime")
        }
        switch method {
        case "agentEvents":
            if let profileID = binding.runtimeProfileID {
                let reference = fields["reference"]?.objectValue
                guard reference?["profileID"]?.stringValue == profileID,
                      binding.conversationID == nil || reference?["conversationID"]?.intValue == binding.conversationID else {
                    throw RuntimeError.bridge("Committed events belong to another Profile/conversation route")
                }
            }
            let eventCount = fields["events"]?.arrayValue?.count ?? 0
            Log.agent.debug("PiDurable committed events chat=\(chatID) count=\(eventCount)")
            for event in fields["events"]?.arrayValue ?? [] { try await receive(event, chatID: chatID) }
            return .null
        case "nativeModel":
            let config = binding.configuration
            var messages = try (fields["messages"]?.arrayValue ?? []).map { try DurableMessageCodec.decode($0, scope: binding.scope, artifactScope: binding.artifactScope) }
            if let transform = config.transformContext {
                messages = await transform(TransformContextRequest(messages: messages, model: config.model))
            }
            if let error = modelInputCompatibilityError(messages: messages, model: config.model) { throw RuntimeError.bridge(error.message) }
            let tools = (fields["tools"]?.arrayValue ?? []).map { value -> ToolSchema in
                let tool = value.objectValue ?? [:]
                return ToolSchema(name: tool["name"]?.stringValue ?? "", description: tool["description"]?.stringValue ?? "",
                                  parameters: tool["parameters"] ?? .object([:]))
            }
            let response = config.client.stream(model: config.model, systemPrompt: fields["systemPrompt"]?.stringValue,
                                                messages: messages, tools: config.client.supportsTools(for: config.model) ? tools : [],
                                                options: config.streamOptions)
            Log.agent.info("PiDurable native model start chat=\(chatID) provider=\(config.client.id) model=\(config.model.id) messages=\(messages.count) tools=\(tools.count)")
            for try await event in response {
                try Task.checkCancellation()
                if case .done(_, let assistant) = event {
                    for block in assistant.content {
                        if case .toolCall(let call) = block { bindings[chatID]?.calls[call.id] = call }
                    }
                }
                stream(DurableMessageCodec.event(event, provider: "ox-native:\(chatID)"))
            }
            Log.agent.info("PiDurable native model complete chat=\(chatID) provider=\(config.client.id)")
            return .null
        case "nativeTool":
            guard let name = fields["name"]?.stringValue, let callID = fields["callID"]?.stringValue,
                  let tool = binding.configuration.tools.first(where: { $0.name == name }) else {
                throw RuntimeError.bridge("Native capability is not registered for this conversation")
            }
            try Task.checkCancellation()
            let result = try await tool.execute(toolCallId: callID, args: fields["arguments"] ?? .object([:]))
            guard result.transientAttachments.isEmpty else {
                throw RuntimeError.bridge("Transient media translation is not yet enabled in this durable rollout; the native effect may have completed. Inspect before retrying.")
            }
            let message = ToolResultMessage(toolCallId: callID, providerCallID: binding.calls[callID]?.providerCallID, toolName: name, content: result.content,
                                            diagnostics: result.diagnostics, isError: result.isError, truncated: result.truncated,
                                            activatedSkills: result.activatedSkills)
            var value: [String: JSONValue] = ["content": .array(DurableMessageCodec.blocks(result.content)), "isError": .bool(result.isError),
                                             "details": .string(try JSONEncoder().encode(message).base64EncodedString())]
            if result.terminate { value["control"] = .object(["terminate": .bool(true)]) }
            return .object(value)
        case "filePermission":
            // This rollout's synthetic namespace is not the user's Profile. Native authority still controls every write.
            guard let action = fields["action"]?.stringValue, ["write", "edit"].contains(action),
                  let path = fields["path"]?.stringValue, !path.isEmpty else { throw RuntimeError.bridge("Invalid virtual-file capability") }
            if let tool = binding.configuration.tools.first as? ChatJavaScriptTool {
                try await tool.chat.requireApproval(action: action == "write" ? Actions.fsWrite : Actions.fsEdit,
                                                    defaultPolicy: .allow, purpose: "Update the isolated durable test workspace")
            } else { throw RuntimeError.bridge("No native permission owner") }
            return .null
        default: throw RuntimeError.bridge("Native capability unavailable")
        }
    }

    private func receive(_ event: JSONValue, chatID: String) async throws {
        guard let fields = event.objectValue, let type = fields["type"]?.stringValue, var binding = bindings[chatID] else { return }
        var events: [AgentEvent] = []
        switch type {
        case "run_start": events = [.runStarted(turnID: nil)]
        case "turn_start":
            binding.assistant = nil
            events = [.generationStarted(model: binding.configuration.model.id, turnID: nil)]
        case "message_start":
            if let value = fields["message"], value.objectValue?["role"]?.stringValue != "system" { events = [.messageStart(try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope))] }
        case "message_update":
            if let value = fields["partial"], case .assistant(let partial) = try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope) {
                // Reconcile the complete committed partial, including whole-block and message replacement operations.
                // Raw provider deltas are deliberately not forwarded to presentation.
                events = [.messageUpdate(partial, event: .start(partial: partial))]
            }
        case "message_end":
            if let value = fields["entry"]?.objectValue?["model"]?.arrayValue?.first, value.objectValue?["role"]?.stringValue != "system" {
                let message = try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope)
                events.append(.messageEnd(message))
                if case .assistant(let assistant) = message {
                    binding.assistant = assistant
                    for block in assistant.content {
                        if case .toolCall(let call) = block { binding.calls[call.id] = call }
                        if case .thinking(let thinking) = block, !thinking.thinking.isEmpty { events.append(.reasoning(thinking.thinking)) }
                    }
                }
            }
        case "tool_execution_start":
            let id = fields["toolCallId"]?.stringValue ?? ""
            let call = binding.calls[id] ?? ToolCall(id: id, name: fields["toolName"]?.stringValue ?? "", arguments: fields["args"] ?? .object([:]))
            binding.calls[id] = call; events = [.toolExecutionStart(toolCall: call)]
        case "tool_execution_end":
            if let id = fields["toolCallId"]?.stringValue, let call = binding.calls.removeValue(forKey: id),
               let value = fields["entry"]?.objectValue?["model"]?.arrayValue?.first,
               case .toolResult(let result) = try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope) {
                events = [.toolExecutionEnd(toolCall: call, result: result)]
            }
        case "turn_end": if let assistant = binding.assistant { events = [.generationFinished(message: assistant, toolResults: [])] }
        default: break
        }
        bindings[chatID] = binding
        for event in events { await binding.emit(event) }
    }
}

/// Handle of one conversation in a shared Profile Session, not an independent harness or transcript store.
nonisolated final class DurableAgentDriver: Sendable {
    let runtime: DurableRuntime
    let host: DurableAgentHost
    let chatID: String
    let scope: ProfileScope
    let runtimeProfileID: String?
    let artifactScope: ProfileScope?
    init(runtime: DurableRuntime, host: DurableAgentHost, chatID: UUID, scope: ProfileScope, runtimeProfileID: UUID? = nil, artifactScope: ProfileScope? = nil) {
        self.runtime = runtime; self.host = host; self.chatID = chatID.uuidString; self.scope = scope
        self.runtimeProfileID = runtimeProfileID?.uuidString
        self.artifactScope = artifactScope
    }
    func run(_ request: AgentRunRequest, configuration: AgentConfiguration, seed: [Message], emit: @escaping DurableAgentHost.EventSink) async throws -> AgentRunResult {
        await host.bind(chatID: chatID, scope: scope, configuration: configuration, runtimeProfileID: runtimeProfileID, artifactScope: artifactScope, emit: emit)
        let config: JSONValue = .object([
            "chatID": .string(chatID), "model": .string(configuration.model.id),
            "systemPrompt": .string(configuration.systemPrompt + """

            <durable_test_workspace>
            The dedicated read/write/edit tools address this Session's isolated, purgeable test workspace, NOT the user's Profile or the filesystem reached through ox.fs. Use these dedicated tools for test workspace files. Their MEMORY.md, SOUL.md, artifacts/ and skills/ paths are synthetic test content; temporary-chat restrictions on REAL Profile mutations do not prohibit editing this separate workspace. Never use ox.fs through execute to stand in for a dedicated workspace tool. Native Ox capabilities remain available through execute and retain all existing permission, temporary-chat, and private-data restrictions. Shell execution is unavailable. Do not claim a file mutation succeeded without its tool result.
            </durable_test_workspace>
            """),
            "contextWindow": .int(configuration.model.maxContext), "maxTokens": .int(configuration.model.maxTokens),
            "reasoning": .bool(configuration.model.reasoning),
            "tools": .array(configuration.tools.map { .object(["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]) }),
            "messages": .array(seed.map { DurableMessageCodec.message($0, provider: "ox-native:\(chatID)") }),
        ])
        let attachment = try await command(.object(["action": .string("attach"), "config": config]))
        guard let reference = attachment.objectValue?["reference"] else { throw RuntimeError.bridge("Missing qualified conversation reference") }
        try await host.expectReference(chatID: chatID, reference: reference)
        let content = request.messages.flatMap { message -> [JSONValue] in
            if case .user = message { return DurableMessageCodec.message(message, provider: configuration.client.id).objectValue?["content"]?.arrayValue ?? [] }
            return []
        }
        let result = try await withTaskCancellationHandler {
            try await command(.object(["action": .string("run"), "chatID": .string(chatID), "content": .array(content),
                                       "requestID": .string(request.turnID?.uuidString ?? UUID().uuidString)]))
        } onCancel: { Task { try? await self.abort() } }
        let messages = try (result.objectValue?["messages"]?.arrayValue ?? []).map { try DurableMessageCodec.decode($0, scope: scope, artifactScope: artifactScope) }
        let status = result.objectValue?["receipt"]?.objectValue?["status"]?.stringValue
        let failure = await host.failure(chatID: chatID)
        let outcome: AgentRunOutcome = status == "done" ? .completed : Task.isCancelled || failure?.0 == "aborted" ? .aborted :
            .failed(message: failure?.0 ?? "Durable submission was not answered: \(result.objectValue?["receipt"]?.jsonString() ?? "unknown")", kind: failure?.1 ?? .provider)
        return AgentRunResult(outcome: outcome, messages: messages, lastTurnTokens: messages.reversed().compactMap {
            if case .assistant(let message) = $0 { return message.usage.totalTokens }; return nil
        }.first ?? 0)
    }
    func abort() async throws { _ = try await command(.object(["action": .string("abort"), "chatID": .string(chatID)])) }
    private func command(_ value: JSONValue) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(try await runtime.command(value.jsonString(), entry: "agentCommand").utf8))
    }
}

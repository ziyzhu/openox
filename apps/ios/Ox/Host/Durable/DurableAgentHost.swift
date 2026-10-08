import Foundation
import UniformTypeIdentifiers

actor DurableAgentHost {
    typealias EventSink = @Sendable (AgentEvent) async -> Void
    nonisolated private struct ToolGeneration: Sendable {
        let context: AgentContext
        let assistant: AssistantMessage
        let committedAssistant: AssistantMessage
        let calls: [String: ToolCall]
        let inputs: ProviderArtifactInputs
    }
    nonisolated private struct ToolHydration: Sendable {
        let id: UUID
        let assistantEntryID: Int
        let task: Task<ToolGeneration, Error>
    }
    nonisolated private struct Binding: Sendable {
        let scope: ProfileScope
        let configuration: AgentConfiguration
        let emit: EventSink
        weak var runtime: DurableRuntime?
        let runtimeProfileID: String?
        let artifactScope: ProfileScope?
        let isolatedWorkspace: Bool
        let latency: TurnLatencyTrace?
        let turnID: UUID?
        var conversationID: Int?
        var context: AgentContext?
        var providerInputs: ProviderArtifactInputs?
        var toolHydration: ToolHydration?
        var modelAssistant: AssistantMessage?
        var assistant: AssistantMessage?
        var calls: [String: ToolCall] = [:]
        var results: [ToolResultMessage] = []
        var emittedReasoning = Set<Int>()

        mutating func reasoningEvents(_ assistant: AssistantMessage, completed: Bool) -> [AgentEvent] {
            assistant.content.enumerated().compactMap { index, block in
                guard completed || index < assistant.content.count - 1,
                      case .thinking(let thinking) = block,
                      !thinking.thinking.isEmpty,
                      emittedReasoning.insert(index).inserted else { return nil }
                return .reasoning(thinking.thinking)
            }
        }
    }
    private var bindings: [String: Binding] = [:]

    func bind(chatID: String, scope: ProfileScope, configuration: AgentConfiguration, runtime: DurableRuntime,
              runtimeProfileID: String? = nil, artifactScope: ProfileScope? = nil, isolatedWorkspace: Bool, emit: @escaping EventSink) throws {
        guard configuration.shouldStopAfterTurn == nil else {
            throw RuntimeError.bridge("Pi Durable does not support shouldStopAfterTurn; remove the hook before running")
        }
        let previous = bindings[chatID]
        if let previous, previous.scope != scope || previous.runtimeProfileID != runtimeProfileID || previous.artifactScope != artifactScope || previous.isolatedWorkspace != isolatedWorkspace {
            throw RuntimeError.bridge("Native conversation cannot change its immutable Profile route")
        }
        previous?.toolHydration?.task.cancel()
        bindings[chatID] = Binding(scope: scope, configuration: configuration, emit: emit, runtime: runtime,
                                   runtimeProfileID: runtimeProfileID, artifactScope: artifactScope, isolatedWorkspace: isolatedWorkspace,
                                   latency: LogContext.latency, turnID: LogContext.turnID, conversationID: previous?.conversationID)
    }

    func expectReference(chatID: String, reference: JSONValue) throws {
        guard let binding = bindings[chatID], let fields = reference.objectValue,
              let profileID = fields["profileID"]?.stringValue, let conversationID = fields["conversationID"]?.intValue,
              (0...9_007_199_254_740_991).contains(conversationID), binding.runtimeProfileID == nil || binding.runtimeProfileID == profileID,
              binding.conversationID == nil || binding.conversationID == conversationID else {
            throw RuntimeError.bridge("Native conversation reference does not match its immutable route")
        }
        bindings[chatID]?.conversationID = conversationID
    }

    func unbind(chatID: String) { bindings.removeValue(forKey: chatID)?.toolHydration?.task.cancel() }

    func failure(chatID: String) -> (String, LLMFailureKind?)? {
        guard let assistant = bindings[chatID]?.assistant else { return nil }
        if assistant.stopReason == .aborted { return ("aborted", nil) }
        return assistant.errorMessage.map { ($0, assistant.failureKind) }
    }

    func handle(_ method: String, _ params: JSONValue, stream: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue {
        guard let fields = params.objectValue, let chatID = fields["chatID"]?.stringValue,
              let binding = bindings[chatID], let runtime = binding.runtime else { throw RuntimeError.bridge("Native conversation is not attached") }
        if method != "agentEvents", StorageRoot.currentScope != binding.scope {
            throw RuntimeError.bridge("Native capability belongs to a stale Profile scope; reacquire its runtime")
        }
        if let profileID = binding.runtimeProfileID {
            let reference = fields["reference"]?.objectValue
            guard reference?["profileID"]?.stringValue == profileID,
                  binding.conversationID == nil || reference?["conversationID"]?.intValue == binding.conversationID else {
                throw RuntimeError.bridge("Native capability belongs to another Profile/conversation route")
            }
        }
        return try await LogContext.$conversationID.withValue(chatID) {
            try await LogContext.$turnID.withValue(binding.turnID) {
                try await LogContext.$latency.withValue(binding.latency) {
                    try await perform(method, fields: fields, chatID: chatID, binding: binding, runtime: runtime, stream: stream)
                }
            }
        }
    }

    private func perform(_ method: String, fields: [String: JSONValue], chatID: String, binding: Binding,
                         runtime: DurableRuntime, stream: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue {
        switch method {
        case "agentEvents":
            Log.agent.debug("PiDurable committed events chat=\(chatID) count=\(fields["events"]?.arrayValue?.count ?? 0)")
            for event in fields["events"]?.arrayValue ?? [] { try await receive(event, chatID: chatID) }
            return .null
        case "nativeModel":
            let config = binding.configuration
            let compaction = fields["purpose"]?.stringValue == "compaction"
            var options = config.streamOptions
            if fields["streamOptions"]?.objectValue?["cacheRetention"]?.stringValue == "none" { options.promptCachePolicy = .disabled }
            if let maxTokens = fields["streamOptions"]?.objectValue?["maxTokens"]?.intValue, maxTokens > 0 { options.maxTokens = maxTokens }
            let inputs = ProviderArtifactInputs()
            defer { withExtendedLifetime(inputs) {} }
            var messages: [Message] = []
            for value in fields["messages"]?.arrayValue ?? [] {
                messages.append(try await DurableMessageCodec.decodeModel(value, scope: binding.scope,
                    artifactScope: binding.artifactScope, runtime: runtime, runtimeProfileID: binding.runtimeProfileID, inputs: inputs))
            }
            if !compaction, let transform = config.transformContext {
                messages = await transform(TransformContextRequest(messages: messages, model: config.model))
            }
            try ProviderArtifactInputs.validate(messages)
            if let error = modelInputCompatibilityError(messages: messages, model: config.model) { throw RuntimeError.bridge(error.message) }
            let systemPrompt = fields["systemPrompt"]?.stringValue
            if !compaction {
                bindings[chatID]?.toolHydration?.task.cancel()
                bindings[chatID]?.toolHydration = nil
                bindings[chatID]?.context = AgentContext(systemPrompt: systemPrompt ?? "", messages: messages, tools: config.tools)
                bindings[chatID]?.providerInputs = inputs
                bindings[chatID]?.modelAssistant = nil
            }
            let tools = (fields["tools"]?.arrayValue ?? []).map { value -> ToolSchema in
                let tool = value.objectValue ?? [:]
                return ToolSchema(name: tool["name"]?.stringValue ?? "", description: tool["description"]?.stringValue ?? "",
                                  parameters: tool["parameters"] ?? .object([:]),
                                  strict: config.tools.first(where: { $0.name == tool["name"]?.stringValue })?.strict ?? true)
            }
            binding.latency?.recordModelStarted(compaction: compaction)
            let startedAt = ContinuousClock.now
            var completion: AssistantMessage?
            var milestones: Set<TurnLatencyTrace.Milestone> = []
            var firstTokenMs: Int64?
            func markFirst(_ milestone: TurnLatencyTrace.Milestone) {
                guard milestones.insert(milestone).inserted else { return }
                if milestone == .firstToken { firstTokenMs = TurnLatencyTrace.milliseconds(startedAt.duration(to: .now)) }
                binding.latency?.mark(milestone)
            }
            defer {
                binding.latency?.recordModelCompleted(completion?.usage)
                let durationMs = TurnLatencyTrace.milliseconds(startedAt.duration(to: .now))
                let ttft = firstTokenMs.map(String.init) ?? "n/a"
                let decodeMs = firstTokenMs.map { durationMs - $0 } ?? 0
                let throughput = if let usage = completion?.usage, TurnLatencyTrace.hasUsage(usage), decodeMs > 0 {
                    String(format: "%.1f", Double(usage.output) * 1_000 / Double(decodeMs))
                } else { "n/a" }
                let outcome = completion?.stopReason.rawValue ?? (Task.isCancelled ? "aborted" : "error")
                Log.agent.info("AgentModel.end purpose=\(compaction ? "compaction" : "generation") provider=\(config.client.id) model=\(config.model.id) outcome=\(outcome) durationMs=\(durationMs) ttftMs=\(ttft) tokensPerSecond=\(throughput) \(TurnLatencyTrace.usageDescription(completion?.usage))")
            }
            let response = config.client.stream(model: config.model, systemPrompt: systemPrompt,
                                                messages: messages, tools: config.client.supportsTools(for: config.model) ? tools : [],
                                                options: options)
            let media = inputs.footprint
            Log.agent.info("PiDurable native model start chat=\(chatID) provider=\(config.client.id) model=\(config.model.id) messages=\(messages.count) tools=\(tools.count) mediaFiles=\(media.files) mediaBytes=\(media.bytes)")
            for try await event in response {
                try Task.checkCancellation()
                switch event {
                case .textDelta(_, let delta, _) where !delta.isEmpty:
                    markFirst(.firstToken)
                    markFirst(.firstTextReceived)
                case .thinkingDelta(_, let delta, _) where !delta.isEmpty:
                    markFirst(.firstToken)
                    markFirst(.firstThinkingReceived)
                case .toolCallDelta, .toolCallEnd:
                    markFirst(.firstToken)
                case .done(_, let assistant), .failed(_, let assistant):
                    completion = assistant
                default: break
                }
                if !compaction, case .done(_, let assistant) = event {
                    bindings[chatID]?.modelAssistant = assistant
                    for block in assistant.content {
                        if case .toolCall(let call) = block { bindings[chatID]?.calls[call.id] = call }
                    }
                }
                stream(DurableMessageCodec.event(event, provider: "ox-native:\(chatID)"))
            }
            Log.agent.info("PiDurable native model complete chat=\(chatID) provider=\(config.client.id)")
            return .null
        case "nativeTool":
            let binding = binding.toolHydration != nil || binding.context == nil || binding.modelAssistant == nil
                ? try await hydrateToolGeneration(fields, chatID: chatID, binding: binding, runtime: runtime) : binding
            guard let name = fields["name"]?.stringValue, let callID = fields["callID"]?.stringValue,
                  let context = binding.context, let assistant = binding.modelAssistant,
                  let call = binding.calls[callID], call.name == name,
                  let arguments = fields["arguments"], call.arguments == arguments else {
                throw RuntimeError.bridge("Native tool call does not match its provider generation")
            }
            if let storedCall = fields["toolCall"],
               try DurableMessageCodec.decodeToolCall(storedCall, scope: binding.scope, artifactScope: binding.artifactScope) != call {
                throw RuntimeError.bridge("Native tool call does not match its authoritative Pi call")
            }
            try Task.checkCancellation()
            var toolContext = context
            toolContext.messages.append(.assistant(assistant))
            let (message, terminate) = await AgentToolExecutor.execute(call, assistantMessage: assistant, context: toolContext,
                beforeToolCall: binding.configuration.beforeToolCall, afterToolCall: binding.configuration.afterToolCall)
            if terminate, assistant.content.filter({ if case .toolCall = $0 { return true }; return false }).count > 1 {
                throw RuntimeError.bridge("Pi Durable cannot terminate a multi-tool round from one native result; the effect may have completed. Inspect before retrying")
            }
            let profileID = (binding.artifactScope ?? binding.scope).profileID
            guard message.transientAttachments.isEmpty || profileID != nil else {
                throw RuntimeError.bridge("Transient media requires a qualified artifact owner")
            }
            var content = DurableMessageCodec.blocks(message.content, profileID: binding.scope.profileID)
            do {
                for attachment in message.transientAttachments {
                    let suffix = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension ?? "bin"
                    let filename = "media-\(UUID().uuidString).\(suffix)"
                    let publication = try await runtime.publishArtifact(data: attachment.data, filename: filename)
                    guard let receipt = publication.objectValue?["artifact"] else { throw RuntimeError.bridge("Missing immutable artifact publication") }
                    content.append(try DurableMessageCodec.transientReference(attachment, receipt: receipt, profileID: profileID!))
                }
            } catch {
                Log.agent.error("PiDurable media publication failed chat=\(chatID) call=\(callID) error=\(error.localizedDescription)")
                throw RuntimeError.bridge("Native tool completed but its media could not be committed: \(error.localizedDescription). Inspect before retrying")
            }
            var value: [String: JSONValue] = ["content": .array(content), "isError": .bool(message.isError),
                                             "details": .string(try DurableMessageCodec.toolDetails(message))]
            if terminate { value["control"] = .object(["terminate": .bool(true)]) }
            return .object(value)
        case "filePermission":
            guard let action = fields["action"]?.stringValue, ["write", "edit"].contains(action),
                  let path = fields["path"]?.stringValue, !path.isEmpty,
                  let tool = binding.configuration.tools.first(where: { $0 is ConversationTool }) as? ConversationTool,
                  let chat = tool.chat else {
                throw RuntimeError.bridge("Invalid virtual-file capability or missing permission owner")
            }
            let nativeAction = action == "write" ? Actions.fsWrite : Actions.fsEdit
            if !binding.isolatedWorkspace {
                try await chat.requireProfileMutation(nativeAction)
                let location = try await chat.virtualMachine.fileSystem.location(path)
                switch location {
                case .skill(let name), .skillFile(let name), .skillResource(let name, _):
                    try await chat.skillsMount.requireWritable(name: name, path: path)
                case .memory, .soul, .artifact:
                    break
                default:
                    throw RuntimeError.bridge("Dedicated Profile tools cannot mutate this path")
                }
            }
            try await chat.requireApproval(action: nativeAction, defaultPolicy: .allow,
                purpose: binding.isolatedWorkspace ? "Update the isolated durable test workspace" : "Update \(path)")
            return .null
        default:
            throw RuntimeError.bridge("Native capability unavailable")
        }
    }

    private func hydrateToolGeneration(_ fields: [String: JSONValue], chatID: String, binding: Binding, runtime: DurableRuntime) async throws -> Binding {
        guard let entryID = fields["assistantEntryID"]?.intValue, (0...9_007_199_254_740_991).contains(entryID),
              let current = bindings[chatID] else { throw RuntimeError.bridge("Missing authoritative Pi tool generation") }
        let hydration: ToolHydration
        if let existing = current.toolHydration {
            guard existing.assistantEntryID == entryID else { throw RuntimeError.bridge("Overlapping Pi tool generation recovery") }
            hydration = existing
        } else {
            let id = UUID()
            hydration = ToolHydration(id: id, assistantEntryID: entryID, task: Task {
                let generation = try await self.readToolGeneration(fields, binding: binding, runtime: runtime)
                try await self.presentToolGeneration(generation, chatID: chatID, hydrationID: id, assistantEntryID: entryID, scope: binding.scope)
                return generation
            })
            bindings[chatID]?.toolHydration = hydration
        }
        _ = try await hydration.task.value
        try Task.checkCancellation()
        guard let restored = bindings[chatID], restored.toolHydration?.id == hydration.id, StorageRoot.currentScope == binding.scope else {
            throw RuntimeError.bridge("Native tool recovery belongs to a stale conversation binding")
        }
        return restored
    }

    private func presentToolGeneration(_ generation: ToolGeneration, chatID: String, hydrationID: UUID, assistantEntryID: Int, scope: ProfileScope) async throws {
        try Task.checkCancellation()
        guard var binding = bindings[chatID], binding.toolHydration?.id == hydrationID, StorageRoot.currentScope == scope else {
            throw RuntimeError.bridge("Recovered generation belongs to a stale conversation binding")
        }
        binding.context = generation.context
        binding.modelAssistant = generation.assistant
        binding.assistant = generation.committedAssistant
        binding.calls = generation.calls
        binding.providerInputs = generation.inputs
        bindings[chatID] = binding
        guard let owner = binding.configuration.tools.first(where: { $0 is ConversationTool }) as? ConversationTool,
              let chat = owner.chat else { throw RuntimeError.bridge("Recovered tool conversation is no longer available") }
        await chat.presentDurableToolAssistant(generation.committedAssistant)
        let media = generation.inputs.footprint
        Log.agent.info("PiDurable native tool generation restored chat=\(chatID) assistantEntry=\(assistantEntryID) mediaFiles=\(media.files) mediaBytes=\(media.bytes) presentation=committed")
    }

    private func readToolGeneration(_ fields: [String: JSONValue], binding: Binding, runtime: DurableRuntime) async throws -> ToolGeneration {
        guard let values = fields["contextMessages"]?.arrayValue, let value = fields["assistant"],
              let systemPrompt = fields["systemPrompt"]?.stringValue, let tools = fields["tools"]?.arrayValue,
              let storedCall = fields["toolCall"], let callID = fields["callID"]?.stringValue,
              let name = fields["name"]?.stringValue, let arguments = fields["arguments"],
              tools.contains(where: { $0.objectValue?["name"]?.stringValue == name }),
              case .assistant(let actual) = try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope) else {
            throw RuntimeError.bridge("Missing authoritative Pi assistant, context, or positional tool set")
        }
        let calls = actual.content.compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { return call }
            return nil
        }
        let call = try DurableMessageCodec.decodeToolCall(storedCall, scope: binding.scope, artifactScope: binding.artifactScope)
        guard Set(calls.map(\.id)).count == calls.count, calls.contains(call), call.id == callID, call.name == name, call.arguments == arguments else {
            throw RuntimeError.bridge("Recovered native tool does not match its actual Pi assistant")
        }
        let inputs = ProviderArtifactInputs()
        var messages: [Message] = []
        for message in values {
            try Task.checkCancellation()
            messages.append(try await DurableMessageCodec.decodeModel(message, scope: binding.scope, artifactScope: binding.artifactScope,
                runtime: runtime, runtimeProfileID: binding.runtimeProfileID, inputs: inputs))
        }
        guard case .assistant(let assistant) = try await DurableMessageCodec.decodeModel(value, scope: binding.scope, artifactScope: binding.artifactScope,
            runtime: runtime, runtimeProfileID: binding.runtimeProfileID, inputs: inputs) else {
            throw RuntimeError.bridge("Recovered Pi message is not an assistant")
        }
        try ProviderArtifactInputs.validate(messages + [.assistant(assistant)])
        return ToolGeneration(context: AgentContext(systemPrompt: systemPrompt, messages: messages, tools: binding.configuration.tools),
                              assistant: assistant, committedAssistant: actual, calls: Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) }), inputs: inputs)
    }

    private func receive(_ event: JSONValue, chatID: String) async throws {
        guard let fields = event.objectValue, let type = fields["type"]?.stringValue, var binding = bindings[chatID] else { return }
        var events: [AgentEvent] = []
        switch type {
        case "run_start":
            binding.latency?.mark(.agentStarted)
            events = [.runStarted(turnID: binding.turnID)]
        case "turn_start":
            binding.assistant = nil
            binding.results = []
            binding.emittedReasoning = []
            events = [.generationStarted(model: binding.configuration.model.id, turnID: binding.turnID)]
        case "message_start":
            if let value = fields["message"], value.objectValue?["role"]?.stringValue != "system" {
                events = [.messageStart(try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope))]
            }
        case "message_update":
            if let value = fields["partial"], case .assistant(let partial) = try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope) {
                events = binding.reasoningEvents(partial, completed: false)
                events.append(.messageUpdate(partial, event: .start(partial: partial)))
            }
        case "message_end":
            if let value = fields["entry"]?.objectValue?["model"]?.arrayValue?.first, value.objectValue?["role"]?.stringValue != "system" {
                let message = try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope)
                if case .assistant(let assistant) = message {
                    binding.assistant = assistant
                    events += binding.reasoningEvents(assistant, completed: true)
                    for block in assistant.content {
                        if case .toolCall(let call) = block { binding.calls[call.id] = call }
                    }
                }
                events.append(.messageEnd(message))
            }
        case "tool_execution_start":
            let id = fields["toolCallId"]?.stringValue ?? ""
            let call = binding.calls[id] ?? ToolCall(id: id, name: fields["toolName"]?.stringValue ?? "", arguments: fields["args"] ?? .object([:]))
            binding.calls[id] = call
            binding.latency?.recordCallStarted(id: id, name: call.name, kind: .tool)
            events = [.toolExecutionStart(toolCall: call)]
        case "tool_execution_end":
            if let id = fields["toolCallId"]?.stringValue, let call = binding.calls.removeValue(forKey: id),
               let value = fields["entry"]?.objectValue?["model"]?.arrayValue?.first,
               case .toolResult(let result) = try DurableMessageCodec.decode(value, scope: binding.scope, artifactScope: binding.artifactScope) {
                binding.results.append(result)
                binding.latency?.recordCallCompleted(id: id, failed: result.isError)
                events = [.toolExecutionEnd(toolCall: call, result: result)]
            }
        case "turn_end":
            if let assistant = binding.assistant { events = [.generationFinished(message: assistant, toolResults: binding.results)] }
            binding.toolHydration?.task.cancel()
            binding.toolHydration = nil
            binding.context = nil
            binding.providerInputs = nil
            binding.modelAssistant = nil
        default: break
        }
        bindings[chatID] = binding
        for event in events { await binding.emit(event) }
    }
}

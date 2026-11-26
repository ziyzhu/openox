import Foundation
import UniformTypeIdentifiers

extension Conversation {
    var remoteAgentName: String? {
        remoteAgent.map { RemoteAgentDirectory.shared.displayName(for: $0.endpoint) }
    }

    var remoteModelName: String? {
        remoteAgent.flatMap { RemoteAgentDirectory.shared.modelName($0.model, endpoint: $0.endpoint) }
    }

    var canChangeAgent: Bool { transcript.isEmpty && queuedMessages.isEmpty && !isBusy && !isTemporary }

    @discardableResult
    func selectAgent(_ endpoint: URL?) -> Bool {
        guard canChangeAgent || remoteAgent?.endpoint == endpoint else { return false }
        guard remoteAgent?.endpoint != endpoint else { return true }
        remoteAgent = endpoint.map { RemoteAgentBinding(endpoint: $0, model: RemoteAgentDirectory.shared.defaultModels[$0]) }
        Log.session.info("Conversation.agent selected id=\(id) agent=\(endpoint?.absoluteString ?? "local")")
        return true
    }

    func selectRemoteModel(_ model: RemoteAgentModel) {
        guard var binding = remoteAgent else { return }
        binding.model = model.reference
        remoteAgent = binding
        Log.session.info("Conversation.agent model id=\(id) provider=\(model.reference.provider) model=\(model.reference.id)")
        guard let conversationID = binding.conversationID else { return }
        let client = RemoteAgentDirectory.shared.client(for: binding.endpoint)
        Task {
            do {
                _ = try await client.call("conversations.setModel", .object([
                    "id": .string(conversationID), "provider": .string(model.reference.provider), "model": .string(model.reference.id),
                ]))
            } catch { Log.session.error("Conversation.agent setModel failed id=\(self.id) error=\(error.localizedDescription)") }
        }
    }

    func submitRemote(_ input: ConversationInput, configuration: AgentConfiguration, binding: RemoteAgentBinding) async throws -> ConversationRunResult {
        let client = RemoteAgentDirectory.shared.client(for: binding.endpoint)
        let result: ConversationRunResult
        do {
            try Task.checkCancellation()
            let context = try await remoteContext(configuration: configuration, turnState: input.turnState)
            let tools: JSONValue = .array(configuration.tools.map {
                .object(["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters])
            })
            let conversationID = try await openRemote(binding, client: client, context: context, tools: tools)
            let inbound = client.inbound(for: conversationID)
            client.setToolHandler({ [weak self] params in
                await self?.callRemoteTool(params, tools: configuration.tools) ?? Self.remoteToolFailure("Ox conversation closed")
            }, for: conversationID)
            defer { client.setToolHandler(nil, for: conversationID) }
            var request = try await remoteMessage(input)
            request["id"] = .string(conversationID)
            request["context"] = context
            Log.session.info("Conversation.remote send id=\(id) agent=\(binding.endpoint.absoluteString) conversation=\(conversationID)")
            let events = RemoteAgentEvents(scope: scope, model: binding.model?.id ?? model.id)
            let message = request
            result = await withTaskCancellationHandler {
                await withTaskGroup(of: ConversationRunResult?.self) { group in
                    group.addTask { @MainActor in
                        do {
                            let sent = try await client.call("conversations.send", .object(message))
                            return sent.objectValue?["disposition"]?.stringValue == "handled" ? ConversationRunResult(outcome: .completed) : nil
                        } catch {
                            return self.remoteFailure(error)
                        }
                    }
                    group.addTask { @MainActor in
                        await self.consumeRemote(inbound, events: events, client: client, conversationID: conversationID)
                    }
                    var outcome = ConversationRunResult(outcome: .aborted)
                    for await value in group {
                        guard let value else { continue }
                        outcome = value
                        break
                    }
                    group.cancelAll()
                    return outcome
                }
            } onCancel: {
                Task { @MainActor in
                    do { _ = try await client.call("conversations.stop", .object(["id": .string(conversationID)]), timeout: .seconds(10)) }
                    catch { Log.session.error("Conversation.remote stop failed conversation=\(conversationID) error=\(error.localizedDescription)") }
                }
            }
        } catch {
            result = Task.isCancelled ? ConversationRunResult(outcome: .aborted) : remoteFailure(error)
        }
        Log.session.info("Conversation.remote finished id=\(id) outcome=\(result.errorMessage ?? "completed")")
        await receiveAgentEvent(.runFinished(result))
        await recordRemoteTurns()
        return result
    }

    private func recordRemoteTurns() async {
        guard let start = turns.lastIndex(where: { if case .user = $0 { true } else { false } }) else { return }
        let recorded = Array(turns[start...])
        do {
            try await Task { try await recordDurableTurns(recorded) }.value
            Log.session.info("Conversation.remote recorded id=\(id) turns=\(recorded.count)")
        } catch {
            Log.session.error("Conversation.remote record failed id=\(id) error=\(error.localizedDescription)")
        }
    }

    private func openRemote(_ binding: RemoteAgentBinding, client: RemoteAgentClient, context: JSONValue, tools: JSONValue) async throws -> String {
        if let conversationID = binding.conversationID {
            guard !client.isOpen(conversationID) else { return conversationID }
            _ = try await client.call("conversations.open", .object(["id": .string(conversationID), "context": context, "tools": tools]))
            client.markOpen(conversationID)
            return conversationID
        }
        var request: [String: JSONValue] = ["context": context, "tools": tools]
        if let model = binding.model { request["model"] = .object(["provider": .string(model.provider), "id": .string(model.id)]) }
        if let thinkingLevel = binding.thinkingLevel { request["thinkingLevel"] = .string(thinkingLevel) }
        let created = try await client.call("conversations.new", .object(request)).objectValue ?? [:]
        guard let conversationID = created["id"]?.stringValue else { throw RemoteAgentError.invalidResponse("conversations.new") }
        client.markOpen(conversationID)
        var next = binding
        next.conversationID = conversationID
        if next.model == nil, let model = created["model"]?.objectValue, let provider = model["provider"]?.stringValue, let id = model["id"]?.stringValue {
            next.model = AgentModelReference(provider: provider, id: id)
        }
        remoteAgent = next
        Log.session.info("Conversation.remote created id=\(id) conversation=\(conversationID)")
        return conversationID
    }

    private func remoteContext(configuration: AgentConfiguration, turnState: JSONValue?) async throws -> JSONValue {
        try await durablePreparation?.value
        guard let route = durableRoute else { throw RuntimeError.bridge("Conversation storage is not ready") }
        let value = try await route.session.runtime.command(.object([
            "action": .string("composeContext"), "promptState": configuration.promptState,
            "turnState": turnState ?? .object([:]), "conversationID": .int(route.conversationID),
        ]))
        let sections = (value.objectValue?["sections"]?.objectValue ?? [:]).reduce(into: [String: JSONValue]()) { $0["ox_\($1.key)"] = $1.value }
        return .object(["sections": .object(sections)])
    }

    private func remoteMessage(_ input: ConversationInput) async throws -> [String: JSONValue] {
        var texts: [String] = []
        var images: [JSONValue] = []
        for case .user(let message) in input.messages {
            for block in message.content {
                switch block {
                case .text(let text): texts.append(text.text)
                case .attachment(let file):
                    if UTType(file.typeIdentifier)?.conforms(to: .image) == true, let data = try? Data(contentsOf: file.fileURL) {
                        images.append(.object(["data": .string(data.base64EncodedString()), "mimeType": .string(file.mimeType)]))
                    } else {
                        texts.append("[Attached file: \(file.userFacingName)]")
                    }
                case .thinking, .toolCall: continue
                }
            }
        }
        var request: [String: JSONValue] = ["text": .string(texts.joined(separator: "\n\n"))]
        if !images.isEmpty { request["images"] = .array(images) }
        return request
    }

    private func consumeRemote(_ inbound: AsyncStream<RemoteAgentInbound>, events: RemoteAgentEvents,
                               client: RemoteAgentClient, conversationID: String) async -> ConversationRunResult {
        var events = events
        var invocations: [String: UUID] = [:]
        var prompts: Set<String> = []
        for await message in inbound {
            switch message {
            case .event(let value):
                let (agentEvents, progress) = events.receive(value)
                for event in agentEvents {
                    presentRemoteTool(event, invocations: &invocations)
                    await receiveAgentEvent(event)
                }
                if case .settled(let aborted) = progress {
                    if aborted { return ConversationRunResult(outcome: .aborted) }
                    if let assistant = events.lastAssistant, assistant.stopReason == .error {
                        return ConversationRunResult(outcome: .failed(message: assistant.errorMessage ?? "The agent failed", kind: .provider))
                    }
                    return ConversationRunResult(outcome: .completed)
                }
            case .prompt(let params):
                guard let promptID = params.objectValue?["promptId"]?.stringValue, prompts.insert(promptID).inserted else { continue }
                Task { await answerRemotePrompt(params, client: client, conversationID: conversationID) }
            case .changed(let params):
                if params.objectValue?["state"]?.stringValue == "exited" {
                    return ConversationRunResult(outcome: .failed(message: params.objectValue?["error"]?.stringValue ?? "The agent process exited", kind: .provider))
                }
            case .disconnected(let reason):
                return remoteFailure(RemoteAgentError.disconnected(reason))
            }
        }
        return ConversationRunResult(outcome: .aborted)
    }

    private func presentRemoteTool(_ event: AgentEvent, invocations: inout [String: UUID]) {
        switch event {
        case .toolExecutionStart(let call) where !configurationToolNames.contains(call.name):
            beginExecution(source: "")
            invocations[call.id] = appendInvocation(name: call.name, purpose: Self.remoteToolPurpose(call), args: call.arguments)
        case .toolExecutionEnd(let call, let result):
            guard let invocation = invocations.removeValue(forKey: call.id) else { return }
            let text = result.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined(separator: "\n")
            resolveInvocation(invocationID: invocation, outcome: result.isError ? .failed(text) : .succeeded(.string(text)))
            finishExecution(output: text, isError: result.isError)
        default:
            return
        }
    }

    private var configurationToolNames: Set<String> { [ConversationTool.schema.name] }

    private func remoteFailure(_ error: Error) -> ConversationRunResult {
        let unreachable = switch error {
        case RemoteAgentError.disconnected, RemoteAgentError.timedOut: true
        case let error as URLError: error.code != .cancelled
        default: false
        }
        Log.session.error("Conversation.remote failed id=\(id) unreachable=\(unreachable) error=\(LogPrivacy.text(error.localizedDescription, limit: 300))")
        guard unreachable else { return ConversationRunResult(outcome: .failed(message: error.localizedDescription, kind: .provider)) }
        let name = remoteAgentName ?? String(localized: "The agent")
        return ConversationRunResult(outcome: .failed(
            message: String(localized: "\(name) is unreachable. Make sure ox agent serve is running there, then try again."), kind: .provider))
    }

    private static func remoteToolPurpose(_ call: ToolCall) -> String {
        let fields = call.arguments.objectValue ?? [:]
        let detail = ["command", "path", "pattern", "file_path"].lazy.compactMap { fields[$0]?.stringValue }.first
        return detail.map { "\(call.name) \($0)" } ?? call.name
    }

    private func callRemoteTool(_ params: JSONValue, tools: [any AgentTool]) async -> JSONValue {
        let fields = params.objectValue ?? [:]
        guard let name = fields["name"]?.stringValue, let tool = tools.first(where: { $0.name == name }) else {
            return Self.remoteToolFailure("Unknown Ox tool")
        }
        let callID = fields["toolCallId"]?.stringValue ?? UUID().uuidString
        let startedAt = ContinuousClock.now
        do {
            let result = try await tool.execute(toolCallId: callID, args: fields["args"] ?? .object([:]))
            Log.session.info("Conversation.remote tool id=\(id) name=\(name) isError=\(result.isError) durationMs=\(TurnLatencyTrace.milliseconds(startedAt.duration(to: .now)))")
            return Self.remoteToolContent(result)
        } catch {
            Log.session.error("Conversation.remote tool failed id=\(id) name=\(name) error=\(error.localizedDescription)")
            return Self.remoteToolFailure(error.localizedDescription)
        }
    }

    private static func remoteToolContent(_ result: ToolResult) -> JSONValue {
        var content: [JSONValue] = result.content.compactMap { block in
            switch block {
            case .text(let text): .object(["type": .string("text"), "text": .string(text.text)])
            case .attachment(let file): .object(["type": .string("text"), "text": .string("[Ox file: \(file.virtualPath ?? file.userFacingName)]")])
            case .thinking, .toolCall: nil
            }
        }
        for attachment in result.transientAttachments where attachment.kind == .image {
            content.append(.object(["type": .string("image"), "data": .string(attachment.data.base64EncodedString()), "mimeType": .string(attachment.mimeType)]))
        }
        return .object(["content": .array(content), "isError": .bool(result.isError)])
    }

    private static func remoteToolFailure(_ message: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)])
    }

    private func answerRemotePrompt(_ params: JSONValue, client: RemoteAgentClient, conversationID: String) async {
        let fields = params.objectValue ?? [:]
        guard let promptID = fields["promptId"]?.stringValue else { return }
        let title = fields["title"]?.stringValue ?? ""
        let text = [title, fields["message"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        var response: [String: JSONValue] = ["id": .string(conversationID), "promptId": .string(promptID)]
        switch fields["method"]?.stringValue {
        case "confirm":
            let allow = String(localized: "Allow")
            let answer = await awaitPrompt(prompt: text, options: [allow, String(localized: "Deny")], kind: .permission)
            response["confirmed"] = .bool(answer == allow)
        case "select":
            let options = fields["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
            response["value"] = .string(await awaitPrompt(prompt: text, options: options))
        default:
            response["value"] = .string(await awaitPrompt(prompt: text, options: [], allowsCustomAnswer: true))
        }
        do { _ = try await client.call("conversations.respond", .object(response)) }
        catch { Log.session.error("Conversation.remote respond failed id=\(id) error=\(error.localizedDescription)") }
    }
}

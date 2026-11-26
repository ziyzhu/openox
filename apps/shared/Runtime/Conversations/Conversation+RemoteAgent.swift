import Foundation
import UniformTypeIdentifiers

extension Conversation {
    var remoteAgentName: String? {
        remoteAgent.map { RemoteAgentDirectory.shared.displayName(for: $0.endpoint) }
    }

    var remoteModelName: String? {
        remoteAgent.flatMap { RemoteAgentDirectory.shared.modelName($0.model, endpoint: $0.endpoint) }
    }

    var remoteThinkingLevel: String? {
        remoteAgent.flatMap { $0.thinkingLevel ?? RemoteAgentDirectory.shared.defaultThinkingLevels[$0.endpoint] }
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
        updateRemoteSelection(model: model, thinking: nil)
    }

    func selectRemoteThinking(_ level: String) {
        updateRemoteSelection(model: nil, thinking: level)
    }

    private func updateRemoteSelection(model: RemoteAgentModel?, thinking: String?) {
        guard let previous = remoteAgent else { return }
        var binding = previous
        if let model { binding.model = model.reference }
        if let thinking { binding.thinkingLevel = thinking }
        if let model, let level = binding.thinkingLevel, !model.thinkingLevels.contains(level) {
            binding.thinkingLevel = Self.clampedThinkingLevel(level, to: model.thinkingLevels)
        }
        guard binding.model != previous.model || binding.thinkingLevel != previous.thinkingLevel else { return }
        remoteAgent = binding
        Log.session.info("Conversation.agent selection id=\(id) model=\(binding.model?.id ?? "default") thinking=\(binding.thinkingLevel ?? "default")")
    }

    private func applyRemoteSelection(client: RemoteAgentClient, conversationID: String) async throws {
        guard let binding = remoteAgent else { return }
        let wanted = RemoteAgentSelection(model: binding.model, thinking: binding.thinkingLevel)
        let current = client.appliedSelection(conversationID)
        guard current != wanted else { return }
        client.markApplied(nil, for: conversationID)
        if let model = binding.model, current?.model != model || binding.thinkingLevel != nil {
            _ = try await client.call("conversations.setModel", .object([
                "id": .string(conversationID), "provider": .string(model.provider), "model": .string(model.id),
            ]))
        }
        if let level = binding.thinkingLevel {
            _ = try await client.call("conversations.setThinking", .object(["id": .string(conversationID), "level": .string(level)]))
        }
        client.markApplied(wanted, for: conversationID)
        Log.session.info("Conversation.remote applied id=\(id) model=\(binding.model?.id ?? "default") thinking=\(binding.thinkingLevel ?? "default")")
    }

    static func clampedThinkingLevel(_ level: String, to levels: [String]) -> String? {
        let order = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        guard let requested = order.firstIndex(of: level) else { return levels.first }
        return order[requested...].first(where: levels.contains) ?? order[..<requested].last(where: levels.contains)
    }

    func submitRemote(_ input: ConversationInput, configuration: AgentConfiguration, binding: RemoteAgentBinding) async throws -> ConversationRunResult {
        let client = RemoteAgentDirectory.shared.client(for: binding.endpoint)
        await recordRemoteTurns(.request)
        let result: ConversationRunResult
        do {
            try Task.checkCancellation()
            let context = try await remoteContext(configuration: configuration, turnState: input.turnState)
            let tools = Self.remoteTools(configuration.tools)
            let (conversationID, openedSeq) = try await openRemote(binding, client: client, context: context, tools: tools)
            try await applyRemoteSelection(client: client, conversationID: conversationID)
            let startSeq = openedSeq ?? binding.lastSeq
            if let startSeq, remoteAgent?.conversationID == conversationID { remoteAgent?.lastSeq = startSeq }
            let inbound = client.inbound(for: conversationID)
            client.setToolHandler({ [weak self] params in
                await self?.callRemoteTool(params, tools: configuration.tools, client: client) ?? Self.remoteToolFailure("Ox conversation closed")
            }, for: conversationID)
            defer { client.setToolHandler(nil, for: conversationID) }
            var request = try await remoteMessage(input, client: client, conversationID: conversationID)
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
                        await self.consumeRemote(inbound, events: events, client: client, session: RemoteSession(
                            conversationID: conversationID, context: context, tools: tools, seq: startSeq))
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
                Self.stopRemote(client: client, conversationID: conversationID)
            }
        } catch {
            result = Task.isCancelled ? ConversationRunResult(outcome: .aborted) : remoteFailure(error)
        }
        return await finishRemote(result)
    }

    func resumeRemoteRun() {
        guard let binding = remoteAgent, let conversationID = binding.conversationID, let since = binding.lastSeq,
              case .user? = turns.last else { return }
        Log.session.info("Conversation.remote resume id=\(id) conversation=\(conversationID) since=\(since)")
        resumeRun("remote=\(conversationID)") { await self.attachRemote(binding, conversationID: conversationID, since: since) }
    }

    private func attachRemote(_ binding: RemoteAgentBinding, conversationID: String, since: Int) async -> ConversationRunResult {
        let client = RemoteAgentDirectory.shared.client(for: binding.endpoint)
        let configuration = agentConfiguration(client: self.client, model: model)
        let result: ConversationRunResult
        do {
            let context = try await remoteContext(configuration: configuration, turnState: await promptTurnState())
            let tools = Self.remoteTools(configuration.tools)
            let inbound = client.inbound(for: conversationID)
            let opened = try await client.call("conversations.open", .object([
                "id": .string(conversationID), "context": context, "tools": tools, "since": .int(since),
            ]))
            client.markOpen(conversationID)
            let fields = opened.objectValue ?? [:]
            let seq = fields["seq"]?.intValue ?? 0
            let running = fields["state"]?.stringValue == "running"
            Log.session.info("Conversation.remote attached id=\(id) since=\(since) seq=\(seq) running=\(running) replay=\(fields["replay"]?.stringValue ?? "none")")
            if fields["replay"]?.stringValue != "complete" || seq < since {
                result = ConversationRunResult(outcome: .failed(message: Self.remoteEndedAway, kind: .provider))
            } else if seq == since, !running {
                result = ConversationRunResult(outcome: .failed(message: String(localized: "This message didn't reach the agent. Send it again."), kind: .provider))
            } else {
                client.setToolHandler({ [weak self] params in
                    await self?.callRemoteTool(params, tools: configuration.tools, client: client) ?? Self.remoteToolFailure("Ox conversation closed")
                }, for: conversationID)
                defer { client.setToolHandler(nil, for: conversationID) }
                let events = RemoteAgentEvents(scope: scope, model: binding.model?.id ?? model.id)
                let session = RemoteSession(conversationID: conversationID, context: context, tools: tools, seq: since)
                result = await withTaskCancellationHandler {
                    await consumeRemote(inbound, events: events, client: client, session: session)
                } onCancel: {
                    Self.stopRemote(client: client, conversationID: conversationID)
                }
            }
        } catch {
            result = Task.isCancelled ? ConversationRunResult(outcome: .aborted) : remoteFailure(error)
        }
        return await finishRemote(result)
    }

    private func finishRemote(_ result: ConversationRunResult) async -> ConversationRunResult {
        Log.session.info("Conversation.remote finished id=\(id) outcome=\(result.errorMessage ?? "completed")")
        await receiveAgentEvent(.runFinished(result))
        await recordRemoteTurns(.reply)
        return result
    }

    private nonisolated static func stopRemote(client: RemoteAgentClient, conversationID: String) {
        Task { @MainActor in
            do { _ = try await client.call("conversations.stop", .object(["id": .string(conversationID)]), timeout: .seconds(10)) }
            catch { Log.session.error("Conversation.remote stop failed conversation=\(conversationID) error=\(error.localizedDescription)") }
        }
    }

    private static var remoteEndedAway: String {
        String(localized: "The agent finished or restarted while Ox was away, so the end of this reply couldn't be shown. Send a message to continue.")
    }

    private static func remoteTools(_ tools: [any AgentTool]) -> JSONValue {
        .array(tools.map { .object(["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]) })
    }

    private func recordRemoteTurns(_ part: RemoteTurnRecord) async {
        guard let start = turns.lastIndex(where: { if case .user = $0 { true } else { false } }) else { return }
        let recorded = switch part {
        case .request: [turns[start]]
        case .reply: Array(turns[(start + 1)...])
        }
        guard !recorded.isEmpty else { return }
        do {
            try await Task { try await recordDurableTurns(recorded) }.value
            Log.session.info("Conversation.remote recorded id=\(id) part=\(part) turns=\(recorded.count)")
        } catch {
            Log.session.error("Conversation.remote record failed id=\(id) part=\(part) error=\(error.localizedDescription)")
        }
    }

    private func openRemote(_ binding: RemoteAgentBinding, client: RemoteAgentClient, context: JSONValue, tools: JSONValue) async throws -> (String, Int?) {
        if let conversationID = binding.conversationID {
            guard !client.isOpen(conversationID) else { return (conversationID, nil) }
            let opened = try await client.call("conversations.open", .object(["id": .string(conversationID), "context": context, "tools": tools]))
            client.markOpen(conversationID)
            return (conversationID, opened.objectValue?["seq"]?.intValue)
        }
        var request: [String: JSONValue] = ["context": context, "tools": tools]
        if let folder = binding.folder { request["cwd"] = .string(folder) }
        if let model = binding.model { request["model"] = .object(["provider": .string(model.provider), "id": .string(model.id)]) }
        if let thinkingLevel = binding.thinkingLevel { request["thinkingLevel"] = .string(thinkingLevel) }
        let created = try await client.call("conversations.new", .object(request)).objectValue ?? [:]
        guard let conversationID = created["id"]?.stringValue else { throw RemoteAgentError.invalidResponse("conversations.new") }
        client.markOpen(conversationID)
        client.markApplied(RemoteAgentSelection(model: binding.model, thinking: binding.thinkingLevel), for: conversationID)
        var next = binding
        next.conversationID = conversationID
        next.cwd = created["cwd"]?.stringValue
        if next.model == nil, let model = created["model"]?.objectValue, let provider = model["provider"]?.stringValue, let id = model["id"]?.stringValue {
            next.model = AgentModelReference(provider: provider, id: id)
        }
        remoteAgent = next
        Log.session.info("Conversation.remote created id=\(id) conversation=\(conversationID) cwd=\(next.cwd == nil ? "unknown" : "reported")")
        return (conversationID, 0)
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

    private func remoteMessage(_ input: ConversationInput, client: RemoteAgentClient, conversationID: String) async throws -> [String: JSONValue] {
        var texts: [String] = []
        var images: [JSONValue] = []
        for case .user(let message) in input.messages {
            for block in message.content {
                switch block {
                case .text(let text): texts.append(text.text)
                case .attachment(let file):
                    if UTType(file.typeIdentifier)?.conforms(to: .image) == true, let data = try? Data(contentsOf: file.fileURL) {
                        images.append(.object(["data": .string(data.base64EncodedString()), "mimeType": .string(file.mimeType)]))
                    } else if let path = await uploadRemote(file, client: client, conversationID: conversationID) {
                        texts.append("[Attached file: \(file.userFacingName), copied to \(path)]")
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
                               client: RemoteAgentClient, session: RemoteSession) async -> ConversationRunResult {
        let conversationID = session.conversationID
        var events = events
        var invocations: [String: UUID] = [:]
        var prompts: Set<String> = []
        var lastSeq = session.seq
        defer { if let lastSeq, remoteAgent?.conversationID == conversationID { remoteAgent?.lastSeq = lastSeq } }
        for await message in inbound {
            switch message {
            case .event(let value, let seq):
                if let seq {
                    guard seq > (lastSeq ?? 0) else { continue }
                    lastSeq = seq
                }
                let adopted = await adoptRemoteImages(value, into: &events)
                let (agentEvents, progress) = events.receive(adopted)
                for event in agentEvents {
                    presentRemoteTool(event, invocations: &invocations)
                    await receiveAgentEvent(event)
                }
                if case .settled(let aborted) = progress {
                    if aborted { return ConversationRunResult(outcome: .aborted) }
                    if let assistant = events.lastAssistant, assistant.stopReason == .error {
                        return remoteModelFailure(assistant)
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
                guard !client.isConnected else { continue }
                switch await reconnectRemote(client: client, session: session, since: lastSeq) {
                case .resumed(let seq): lastSeq = seq
                case .ended(let message):
                    return ConversationRunResult(outcome: .failed(message: message, kind: .provider))
                case .unreachable:
                    return remoteFailure(RemoteAgentError.disconnected(reason))
                }
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
            for case .attachment(let file) in result.content { embedFile(file) }
            resolveInvocation(invocationID: invocation, outcome: result.isError ? .failed(text) : .succeeded(.string(text)))
            finishExecution(output: text, isError: result.isError)
        default:
            return
        }
    }

    private var configurationToolNames: Set<String> { [ConversationTool.schema.name] }

    private func reconnectRemote(client: RemoteAgentClient, session: RemoteSession, since: Int?) async -> RemoteReconnect {
        let deadline = ContinuousClock.now + .seconds(600)
        var delay: Duration = .seconds(1)
        var attempt = 0
        while ContinuousClock.now < deadline, !Task.isCancelled {
            attempt += 1
            do {
                var request: [String: JSONValue] = ["id": .string(session.conversationID), "context": session.context, "tools": session.tools]
                if let since { request["since"] = .int(since) }
                let opened = try await client.call("conversations.open", .object(request), timeout: .seconds(15))
                client.markOpen(session.conversationID)
                let fields = opened.objectValue ?? [:]
                let replay = fields["replay"]?.stringValue ?? "none"
                let seq = fields["seq"]?.intValue ?? 0
                let restarted = seq < (since ?? 0)
                Log.session.info("Conversation.remote reconnected id=\(id) attempt=\(attempt) since=\(since ?? -1) seq=\(seq) replay=\(replay) restarted=\(restarted)")
                guard replay == "gap" || restarted else { return .resumed(seq: since) }
                if fields["state"]?.stringValue == "idle" || restarted { return .ended(Self.remoteEndedAway) }
                return .resumed(seq: seq)
            } catch {
                Log.session.info("Conversation.remote reconnect id=\(id) attempt=\(attempt) error=\(LogPrivacy.text(error.localizedDescription, limit: 200))")
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(15))
            }
        }
        return .unreachable
    }

    var localSubscriptionAccount: (any SubscriptionAccount)? {
        remoteAgent == nil ? ProviderRegistry.shared.client(id: modelSelection.providerID)?.subscriptionAccount : nil
    }

    private func remoteModelFailure(_ assistant: AssistantMessage) -> ConversationRunResult {
        let raw = assistant.errorMessage ?? String(localized: "The agent's model request failed")
        let status = raw.prefix(while: \.isNumber).count == 3 ? Int(raw.prefix(3)) : nil
        let detail = Self.providerErrorDetail(raw)
        let kind = llmFailureKind(statusCode: status, message: raw)
        let agent = remoteAgentName ?? String(localized: "The agent")
        let provider = remoteAgent?.model?.provider ?? String(localized: "its provider")
        Log.session.error("Conversation.remote model failed id=\(id) kind=\(kind.rawValue) status=\(status ?? 0) error=\(LogPrivacy.text(raw, limit: 300))")
        let message = switch kind {
        case .authentication: String(localized: "\(agent) couldn't sign in to \(provider): \(detail). Log in again on that computer (run pi, then /login), then retry.")
        case .rateLimited, .network: raw
        case .contextOverflow: String(localized: "This conversation is too long for \(assistant.model) on \(agent): \(detail)")
        case .unsupportedInput, .provider: String(localized: "\(provider) error on \(agent): \(detail)")
        }
        return ConversationRunResult(outcome: .failed(message: message, kind: kind))
    }

    private static func providerErrorDetail(_ raw: String) -> String {
        guard let start = raw.firstIndex(of: "{"), let data = String(raw[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return raw }
        let error = object["error"] as? [String: Any]
        return (error?["message"] as? String) ?? (object["message"] as? String) ?? raw
    }

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

    private func callRemoteTool(_ params: JSONValue, tools: [any AgentTool], client: RemoteAgentClient) async -> JSONValue {
        let fields = params.objectValue ?? [:]
        guard let name = fields["name"]?.stringValue, let tool = tools.first(where: { $0.name == name }) else {
            return Self.remoteToolFailure("Unknown Ox tool")
        }
        let callID = fields["toolCallId"]?.stringValue ?? UUID().uuidString
        let startedAt = ContinuousClock.now
        do {
            let result = try await tool.execute(toolCallId: callID, args: fields["args"] ?? .object([:]))
            Log.session.info("Conversation.remote tool id=\(id) name=\(name) isError=\(result.isError) durationMs=\(TurnLatencyTrace.milliseconds(startedAt.duration(to: .now)))")
            return await remoteToolContent(result, client: client, conversationID: fields["id"]?.stringValue ?? "")
        } catch {
            Log.session.error("Conversation.remote tool failed id=\(id) name=\(name) error=\(error.localizedDescription)")
            return Self.remoteToolFailure(error.localizedDescription)
        }
    }

    private func remoteToolContent(_ result: ToolResult, client: RemoteAgentClient, conversationID: String) async -> JSONValue {
        var content: [JSONValue] = []
        for block in result.content {
            switch block {
            case .text(let text):
                content.append(Self.remoteText(text.text))
            case .attachment(let file):
                let name = file.virtualPath ?? file.userFacingName
                let path = await uploadRemote(file, client: client, conversationID: conversationID)
                content.append(Self.remoteText(path.map { "[Ox file: \(name), copied to \($0)]" } ?? "[Ox file: \(name)]"))
            case .thinking, .toolCall:
                continue
            }
        }
        for attachment in result.transientAttachments {
            if attachment.kind == .image {
                content.append(.object(["type": .string("image"), "data": .string(attachment.data.base64EncodedString()), "mimeType": .string(attachment.mimeType)]))
            } else if let path = await uploadRemote(attachment.data, name: attachment.displayName, client: client, conversationID: conversationID) {
                content.append(Self.remoteText("[Ox file: \(attachment.displayName), copied to \(path)]"))
            } else {
                content.append(Self.remoteText("[Ox file: \(attachment.displayName) could not be copied to this machine]"))
            }
        }
        return .object(["content": .array(content), "isError": .bool(result.isError)])
    }

    private static func remoteText(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    private func uploadRemote(_ file: FileItem, client: RemoteAgentClient, conversationID: String) async -> String? {
        do {
            let data = try Data(contentsOf: file.fileURL)
            return await uploadRemote(data, name: file.displayName, client: client, conversationID: conversationID)
        } catch {
            Log.session.error("Conversation.remote upload unreadable id=\(id) file=\(file.fileName) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func uploadRemote(_ data: Data, name: String, client: RemoteAgentClient, conversationID: String) async -> String? {
        let startedAt = ContinuousClock.now
        let chunkBytes = 4 * 1024 * 1024
        var offset = 0
        do {
            repeat {
                let end = min(offset + chunkBytes, data.count)
                let written = try await client.call("files.write", .object([
                    "id": .string(conversationID), "name": .string(FileStore.sanitizedFilename(name)),
                    "size": .int(data.count), "offset": .int(offset), "data": .string(data[offset..<end].base64EncodedString()),
                ]))
                offset = end
                if let path = written.objectValue?["path"]?.stringValue {
                    Log.session.info("Conversation.remote upload id=\(id) bytes=\(data.count) durationMs=\(TurnLatencyTrace.milliseconds(startedAt.duration(to: .now)))")
                    return path
                }
            } while offset < data.count
            Log.session.error("Conversation.remote upload incomplete id=\(id) bytes=\(data.count)")
        } catch {
            Log.session.error("Conversation.remote upload failed id=\(id) bytes=\(data.count) offset=\(offset) error=\(LogPrivacy.text(error.localizedDescription, limit: 200))")
        }
        return nil
    }

    private func adoptRemoteImages(_ event: JSONValue, into events: inout RemoteAgentEvents) async -> JSONValue {
        guard var fields = event.objectValue, fields["type"]?.stringValue == "tool_execution_end",
              var result = fields["result"]?.objectValue, let content = result["content"]?.arrayValue,
              content.contains(where: { $0.objectValue?["type"]?.stringValue == "image" }) else { return event }
        var adopted: [JSONValue] = []
        for block in content {
            guard let image = block.objectValue, image["type"]?.stringValue == "image",
                  let data = image["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
                adopted.append(block)
                continue
            }
            let suffix = image["mimeType"]?.stringValue.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "png"
            do {
                let file = try await importAttachment(data: data, suggestedName: "Agent image.\(suffix)")
                events.adopt(file)
                adopted += DurableMessageCodec.blocks([.attachment(file)])
                Log.session.info("Conversation.remote image adopted id=\(id) file=\(file.fileName) bytes=\(data.count)")
            } catch {
                Log.session.error("Conversation.remote image failed id=\(id) bytes=\(data.count) error=\(error.localizedDescription)")
                adopted.append(block)
            }
        }
        result["content"] = .array(adopted)
        fields["result"] = .object(result)
        return .object(fields)
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

nonisolated enum RemoteTurnRecord: Sendable {
    case request
    case reply
}

nonisolated enum RemoteReconnect: Sendable {
    case resumed(seq: Int?)
    case ended(String)
    case unreachable
}

nonisolated struct RemoteSession: Sendable {
    let conversationID: String
    let context: JSONValue
    let tools: JSONValue
    let seq: Int?
}

extension Conversation {
    func remoteAppModel(_ binding: RemoteAgentBinding) async -> JSONValue {
        let directory = RemoteAgentDirectory.shared
        await directory.refreshUnknown()
        let reference = binding.model ?? directory.defaultModels[binding.endpoint]
        let online = directory.statuses[binding.endpoint]?.isOnline == true
        return .object([
            "agent": .object([
                "name": .string(directory.displayName(for: binding.endpoint)),
                "address": .string(binding.endpoint.absoluteString),
                "machine": directory.machine(for: binding.endpoint).map(JSONValue.string) ?? .null,
                "folder": (binding.cwd ?? binding.folder).map(JSONValue.string) ?? .null,
            ]),
            "provider": .object(["id": .string(reference?.provider ?? "agent"), "name": .string(reference?.provider ?? directory.displayName(for: binding.endpoint))]),
            "model": .object(["id": .string(reference?.id ?? "default"), "name": .string(reference.flatMap { directory.modelName($0, endpoint: binding.endpoint) } ?? reference?.id ?? "Agent default")]),
            "agentDefault": .bool(binding.model == nil),
            "supportsTools": .bool(true),
            "thinkingLevel": remoteThinkingLevel.map(JSONValue.string) ?? .null,
            "change": .null,
            "authentication": .object([
                "method": .string("agent"), "status": .string(online ? "ready" : "unavailable"),
                "settingsPath": .string("Settings > Agents"),
            ]),
        ])
    }

    func setRemoteAppModel(_ options: JSONValue, binding: RemoteAgentBinding) async throws -> JSONValue {
        let directory = RemoteAgentDirectory.shared
        if directory.models[binding.endpoint]?.isEmpty ?? true { await directory.refresh(binding.endpoint) }
        let fields = options.objectValue?["selection"]?.objectValue ?? [:]
        let available = directory.models[binding.endpoint] ?? []
        guard let provider = fields["provider"]?.stringValue, let modelID = fields["model"]?.stringValue,
              let model = available.first(where: { $0.reference == AgentModelReference(provider: provider, id: modelID) }) else {
            let examples = available.prefix(20).map { "\($0.reference.provider)/\($0.reference.id)" }.joined(separator: ", ")
            throw OxFunctionError(code: "invalid_argument",
                message: "ox.conversation.setModel: this conversation runs on the agent \(directory.displayName(for: binding.endpoint)), which has no model \(fields["provider"]?.stringValue ?? "?")/\(fields["model"]?.stringValue ?? "?").",
                recovery: available.isEmpty ? "The agent's models are unavailable; check that it is reachable in app/status.json." : "Use a provider and model from the agent, for example: \(examples).")
        }
        if let level = fields["thinkingLevel"]?.stringValue, !model.thinkingLevels.contains(level) {
            throw OxFunctionError(code: "invalid_argument", message: "ox.conversation.setModel: \(model.name) does not support thinking level \(level).",
                recovery: "Use one of: \(model.thinkingLevels.joined(separator: ", ")).")
        }
        let changed = binding.model != model.reference || (fields["thinkingLevel"]?.stringValue).map { $0 != remoteThinkingLevel } == true
        updateRemoteSelection(model: model, thinking: fields["thinkingLevel"]?.stringValue)
        return .object([
            "status": .string(binding.conversationID == nil || !isBusy ? "applied" : "pending"),
            "selection": .object(["provider": .string(provider), "model": .string(modelID)]),
            "changed": .bool(changed),
        ])
    }
}

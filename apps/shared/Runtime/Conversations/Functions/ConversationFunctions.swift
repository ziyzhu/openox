import Foundation

extension Conversation {
    private static let maximumWaitSeconds = 600
    private static let defaultWaitSeconds = 120
    private static let maximumReadMessages = 20
    private static let maximumMessageCharacters = 4_000

    public func deleteConversation(id: String, purpose: String) async throws -> JSONValue? {
        try requireProfileMutation(Actions.conversationDelete)
        guard let targetID = UUID(uuidString: id), let manager = conversationManager else {
            throw RuntimeError.bridge("ox.conversation.delete: a valid conversation ID and active Profile are required.")
        }
        let target = try await manager.deletionTarget(targetID, requestedBy: self)
        let args: JSONValue = .object([
            "id": .string(targetID.uuidString),
            "title": .string(target.displayTitle),
            "effect": .string(L10n.string("This removes the conversation from your history. This can't be undone.")),
        ])
        return try await tracked(Actions.conversationDelete, args, purpose: purpose) {
            try Task.checkCancellation()
            _ = try await manager.deletionTarget(targetID, requestedBy: self)
            guard let deletion = manager.delete(targetID) else {
                throw RuntimeError.bridge("ox.conversation.delete: the conversation is no longer available.")
            }
            try await deletion.value
            Log.session.info("bridge.conversation.delete caller=\(self.id) target=\(targetID)")
            return .object(["id": .string(targetID.uuidString), "deleted": .bool(true)])
        }
    }

    public func startChildConversation(options: JSONValue, purpose: String) async throws -> JSONValue? {
        try requireProfileMutation(Actions.conversationStart)
        let fields = options.objectValue ?? [:]
        guard let prompt = fields["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw RuntimeError.bridge("ox.conversation.start: prompt must not be empty.")
        }
        let title = fields["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domains = fields["services"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let agent = try Self.childAgent(fields)
        var argFields: [String: JSONValue] = ["prompt": .string(prompt), "title": .string(title ?? ""), "services": .array(domains.map(JSONValue.string))]
        if let agent { argFields["agent"] = .string(RemoteAgentDirectory.shared.displayName(for: agent.endpoint)) }
        if let folder = agent?.folder { argFields["folder"] = .string(folder) }
        let args: JSONValue = .object(argFields)
        return try await tracked(Actions.conversationStart, args, purpose: purpose) {
            try self.requireProfileMutation(Actions.conversationStart)
            guard let manager = self.conversationManager else {
                throw RuntimeError.bridge("ox.conversation.start: an active Profile is required.")
            }
            let services = domains.isEmpty ? [] : try await self.serviceManager.prepareServices(
                domains: domains,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            try Task.checkCancellation()
            let child = try await manager.startChild(prompt: prompt, title: title, services: services, agent: agent, requestedBy: self)
            return Self.childValue(child)
        }
    }

    private static func childAgent(_ fields: [String: JSONValue]) throws -> RemoteAgentBinding? {
        guard let name = fields["agent"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            if fields["folder"] != nil { throw RuntimeError.bridge("ox.conversation.start: folder requires agent.") }
            return nil
        }
        let directory = RemoteAgentDirectory.shared
        guard let agent = directory.agent(named: name) else {
            let names = directory.agents.map(\.name)
            throw OxFunctionError(code: "unknown_agent", message: "ox.conversation.start: no agent named \"\(name)\".",
                recovery: names.isEmpty ? "No remote agents are set up; omit agent to run on this device, or ask the user to add one in Settings → Agents."
                    : "Use one of: \(names.joined(separator: ", ")); or omit agent to run on this device.")
        }
        let folder = fields["folder"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteAgentBinding(endpoint: agent.endpoint, model: directory.newConversationModel(for: agent.endpoint), folder: folder?.isEmpty == false ? folder : nil)
    }

    public func sendChildConversation(id: String, text: String, purpose: String) async throws -> JSONValue? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RuntimeError.bridge("ox.conversation.send: text must not be empty.") }
        return try await tracked(Actions.conversationSend, .object(["id": .string(id), "text": .string(text)]), purpose: purpose) {
            let child = try await self.loadChild(id)
            child.enqueue(text)
            Log.session.info("delegation.send parent=\(self.id) child=\(child.id) chars=\(text.count)")
            return Self.childValue(child)
        }
    }

    public func waitChildConversation(id: String, timeoutSeconds: Int?, purpose: String) async throws -> JSONValue? {
        let timeout = min(max(timeoutSeconds ?? Self.defaultWaitSeconds, 1), Self.maximumWaitSeconds)
        return try await tracked(Actions.conversationWait, .object(["id": .string(id), "timeoutSeconds": .int(timeout)]), purpose: purpose) {
            let child = try await self.loadChild(id)
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while ChildConversationState(child) == .running, !child.hasPendingInteraction, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let state = ChildConversationState(child)
            Log.session.info("delegation.wait parent=\(self.id) child=\(child.id) state=\(state.label) timeout=\(timeout)")
            var value = Self.childValue(child).objectValue ?? [:]
            if state != .running, let reply = Self.latestReply(in: child.transcript) { value["reply"] = .string(reply) }
            return .object(value)
        }
    }

    public func readChildConversation(id: String, after: String?, purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.conversationRead, .object(["id": .string(id), "after": after.map(JSONValue.string) ?? .null]), purpose: purpose) {
            let child = try await self.loadChild(id)
            let messages = Self.messages(in: child.transcript)
            let start = after.flatMap { cursor in messages.firstIndex { $0.id.uuidString == cursor }.map { $0 + 1 } } ?? 0
            let page = Array(messages[start...].suffix(Self.maximumReadMessages))
            var value = Self.childValue(child).objectValue ?? [:]
            value["messages"] = .array(page.map(\.value))
            value["cursor"] = page.last.map { .string($0.id.uuidString) } ?? after.map(JSONValue.string) ?? .null
            return .object(value)
        }
    }

    public func stopChildConversation(id: String, purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.conversationStop, .object(["id": .string(id)]), purpose: purpose) {
            let child = try await self.loadChild(id)
            let wasRunning = child.isBusy
            child.stopCurrentTurn()
            Log.session.info("delegation.stop parent=\(self.id) child=\(child.id) by=parent wasRunning=\(wasRunning)")
            return .object(["id": .string(child.id.uuidString), "wasRunning": .bool(wasRunning)])
        }
    }

    public func listChildConversations(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.conversationChildren, .object([:]), purpose: purpose) {
            let children = self.conversationManager?.children(of: self) ?? []
            return .object(["children": .array(children.map(\.value))])
        }
    }

    private func loadChild(_ id: String) async throws -> Conversation {
        guard let rawID = UUID(uuidString: id), let manager = conversationManager else {
            throw OxFunctionError(code: "invalid_arguments", message: "ox.conversation: a valid child conversation id is required.", recovery: "Use an id from the child_conversations section or ox.conversation.children.")
        }
        return try await manager.child(rawID, of: self)
    }

    private static func childValue(_ child: Conversation) -> JSONValue {
        ChildConversationSnapshot(id: child.id, title: child.metadata.displayTitle,
            state: ChildConversationState(child), updatedAt: child.metadata.activityDate).value
    }

    private struct ChildMessage {
        let id: UUID
        let role: String
        let text: String
        let at: Date

        var value: JSONValue {
            .object(["id": .string(id.uuidString), "role": .string(role), "text": .string(text), "at": .string(ISODate.string(from: at))])
        }
    }

    private static func messages(in transcript: [Block]) -> [ChildMessage] {
        transcript.compactMap { block in
            let role: String
            let text: String
            switch block.kind {
            case .userText(let value, _):
                role = "user"; text = value
            case .agentContent(let items):
                role = "assistant"
                text = items.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined(separator: "\n")
            default:
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ChildMessage(id: block.id, role: role, text: String(trimmed.prefix(maximumMessageCharacters)), at: block.createdAt)
        }
    }

    private static func latestReply(in transcript: [Block]) -> String? {
        let replies = messages(in: transcript).reversed().prefix { $0.role == "assistant" }
        let text = replies.reversed().map(\.text).joined(separator: "\n\n")
        return text.isEmpty ? nil : String(text.prefix(maximumMessageCharacters))
    }
}

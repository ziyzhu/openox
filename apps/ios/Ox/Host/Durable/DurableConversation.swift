import Foundation
import Synchronization

nonisolated private enum SubmissionCancellation {
    case ready
    case aborting(Task<Void, Never>)
    case settled
}

nonisolated struct DurableConversationRoute: Sendable {
    let session: DurableProfileStore.Session
    let nativeID: UUID
    let profileID: UUID
    let artifactScope: ProfileScope?
    let reference: DurableConversationReference?
}

extension Conversation {
    func renderPrompt(configuration: AgentConfiguration) async throws -> RenderedChatPrompt {
        try await durablePreparation?.value
        guard let route = durableRoute else { throw RuntimeError.bridge("Pi conversation preparation has not completed") }
        let value = try await route.session.runtime.command(.object([
            "action": .string("composePrompt"), "promptState": configuration.promptState,
        ]))
        return try JSONDecoder().decode(RenderedChatPrompt.self, from: Data(value.jsonString().utf8))
    }

    func prepareDurableConversation(configuration: AgentConfiguration) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let route = durableRoute else { throw RuntimeError.bridge("Pi conversation preparation has not completed") }
        let session = route.session
        let chatID = route.nativeID.uuidString
        if let reference = route.reference {
            guard reference.profileID == scope.profileID else {
                throw RuntimeError.bridge("Conversation does not belong to its Profile")
            }
        }
        try await session.host.bind(chatID: chatID, scope: scope, configuration: configuration, runtime: session.runtime,
                                    runtimeProfileID: route.profileID.uuidString, artifactScope: route.artifactScope,
                                    isolatedWorkspace: route.reference == nil) { [weak self] event in
            await self?.receiveAgentEvent(event)
        }
        if let reference = route.reference { try await session.host.expectReference(chatID: chatID, reference: reference.value) }
        let effort = configuration.model.selectedReasoningEffort
        let thinkingLevel = effort.flatMap { ["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains($0) ? $0 : nil }
        let config: JSONValue = .object([
            "chatID": .string(chatID), "model": .string(configuration.model.id), "promptState": configuration.promptState,
            "isolatedWorkspace": .bool(route.reference == nil),
            "providerID": .string(configuration.client.id),
            "thinkingLevel": thinkingLevel.map(JSONValue.string) ?? .null,
            "nativeReasoningEffort": thinkingLevel == nil ? effort.map(JSONValue.string) ?? .null : .null,
            "contextWindow": .int(configuration.model.maxContext), "maxTokens": .int(configuration.model.maxTokens),
            "reasoning": .bool(configuration.model.reasoning),
            "toolExecutionMode": .string(configuration.toolExecutionMode == .parallel ? "parallel" : "sequential"),
            "tools": .array(configuration.tools.map { .object([
                "name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters,
                "executionMode": .string($0.executionMode == .parallel ? "parallel" : "sequential"),
            ]) }),
            "messages": .array([]),
        ])
        let attachment = try await session.runtime.command(.object(["action": .string("attach"), "config": config, "reference": route.reference?.value ?? .null]))
        guard let reference = attachment.objectValue?["reference"] else { throw RuntimeError.bridge("Missing qualified conversation reference") }
        try await session.host.expectReference(chatID: chatID, reference: reference)
        preparedConfiguration = configuration
        return reference
    }

    func submit(_ input: ConversationInput, configuration: AgentConfiguration) async throws -> ConversationRunResult {
        let content = input.messages.flatMap { message -> [JSONValue] in
            if case .user = message {
                return DurableMessageCodec.message(message, provider: configuration.client.id, profileID: scope.profileID).objectValue?["content"]?.arrayValue ?? []
            }
            return []
        }
        var fields: [String: JSONValue] = ["content": .array(content), "requestID": .string(input.turnID?.uuidString ?? UUID().uuidString)]
        if let turnState = input.turnState { fields["turnState"] = turnState }
        return try await executeSubmission(action: "run", fields: fields, configuration: configuration)
    }

    func resumeSubmission(_ submissionID: Int, requestID: String?) async throws -> ConversationRunResult {
        var fields: [String: JSONValue] = ["submissionID": .int(submissionID)]
        if let requestID { fields["requestID"] = .string(requestID) }
        return try await executeSubmission(action: "resumeExisting", fields: fields,
            configuration: agentConfiguration(client: client, model: model))
    }

    private func executeSubmission(action: String, fields: [String: JSONValue], configuration: AgentConfiguration) async throws -> ConversationRunResult {
        try Task.checkCancellation()
        guard let route = durableRoute else { throw RuntimeError.bridge("Pi conversation preparation has not completed") }
        let cancellation = Mutex(SubmissionCancellation.ready)
        let result: ConversationRunResult
        do {
            let reference = try await prepareDurableConversation(configuration: configuration)
            try Task.checkCancellation()
            let request = fields.merging(["action": .string(action), "chatID": .string(route.nativeID.uuidString),
                                          "reference": reference]) { _, value in value }
            let response = try await withTaskCancellationHandler {
                try await route.session.runtime.command(.object(request))
            } onCancel: {
                cancellation.withLock { state in
                    guard case .ready = state else { return }
                    state = .aborting(Task {
                        do {
                            _ = try await route.session.runtime.command(.object(["action": .string("abort"),
                                "chatID": .string(route.nativeID.uuidString), "reference": reference]))
                        } catch { Log.agent.error("PiDurable abort failed conversation=\(route.nativeID) error=\(error.localizedDescription)") }
                    })
                }
            }
            let status = response.objectValue?["receipt"]?.objectValue?["status"]?.stringValue
            let failure = await route.session.host.failure(chatID: route.nativeID.uuidString)
            let outcome: ConversationRunOutcome = Task.isCancelled || failure?.0 == "aborted" ? .aborted : status == "done" ? .completed :
                .failed(message: failure?.0 ?? "Durable submission was not answered: \(response.objectValue?["receipt"]?.jsonString() ?? "unknown")", kind: failure?.1 ?? .provider)
            result = ConversationRunResult(outcome: outcome)
        } catch {
            result = ConversationRunResult(outcome: Task.isCancelled ? .aborted :
                .failed(message: error.localizedDescription, kind: llmFailureKind(error: error)))
        }
        let abort = cancellation.withLock { state -> Task<Void, Never>? in
            let task: Task<Void, Never>? = if case .aborting(let task) = state { task } else { nil }
            state = .settled
            return task
        }
        await abort?.value
        await receiveAgentEvent(.runFinished(result))
        return result
    }

    func canonicalMessages() async throws -> [Message] {
        try await durablePreparation?.value
        guard let route = durableRoute else { throw RuntimeError.bridge("Pi conversation is not attached") }
        let result = try await route.session.runtime.command(.object(["action": .string("conversationContext"),
            "chatID": .string(route.nativeID.uuidString), "reference": route.reference?.value ?? .null]))
        guard let messages = result.objectValue?["messages"]?.arrayValue else { throw RuntimeError.bridge("Invalid Pi conversation context") }
        return try messages.map {
            try DurableMessageCodec.decode($0, scope: scope, artifactScope: route.artifactScope)
        }
    }
}

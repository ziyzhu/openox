import Foundation

@MainActor
final class WebModelContext {
    private struct Configuration: Equatable {
        let modelID: String
        let temperature: Double?
        let maxTokens: Int?
    }

    struct Turn {
        let previousGenerationID: String?
        let messages: [JSONValue]
    }

    struct Generation {
        let id: String
    }

    private let service: Service
    private let conversation: WebConversation
    private var page: Service.ServiceWebPage { conversation.page }
    private let configuration: Configuration
    private var usesConversation: Bool { service.definition.supportsConversation }
    private var supportsContinuation: Bool {
        usesConversation ? conversation.continuation : service.definition.action(ModelServiceContract.resume, includingStandard: true) != nil
    }
    private var hasContinuationCapacity: Bool {
        completedGenerations < ModelServiceContract.maximumSubmissions
            && retainedResponseBytes <= ModelServiceContract.maximumRetainedResponseBytes - ModelServiceContract.maximumResponseBytes
    }
    private var completedGenerations = 0
    private var retainedResponseBytes = 0
    private var lastGenerationID: String?
    private var history: [JSONValue] = []
    private var isClosed = false

    private init(service: Service, conversation: WebConversation, configuration: Configuration) {
        self.service = service
        self.conversation = conversation
        self.configuration = configuration
    }

    static func checkout(service: Service, chatID: UUID?, modelID: String, options: StreamOptions, messages: [JSONValue]) async throws -> (WebModelContext, Turn) {
        let configuration = Configuration(modelID: modelID, temperature: options.temperature, maxTokens: options.maxTokens)
        await service.loadManifest()
        var reason = chatID == nil ? "unkeyed" : "none"
        if let chatID, let existing = service.manager.webModelContexts.removeValue(forKey: chatID) {
            if let failure = existing.mismatch(service: service, configuration: configuration) {
                reason = failure
            } else if let previous = existing.lastGenerationID,
                      let turns = WebModelHistory.newTurns(after: existing.history, in: messages) {
                Log.service.info("ModelService.continue domain=\(service.domain) previous=\(previous) newTurns=\(turns.count) page=\(existing.page.logLabel)")
                return (existing, Turn(previousGenerationID: previous, messages: turns))
            } else {
                reason = "history"
            }
            existing.close()
        }
        let context = try await open(service: service, configuration: configuration, chatID: chatID)
        Log.service.info("ModelService.fresh domain=\(service.domain) reason=\(reason) turns=\(messages.count) page=\(context.page.logLabel)")
        return (context, Turn(previousGenerationID: nil, messages: messages))
    }

    private static func open(service: Service, configuration: Configuration, chatID: UUID?) async throws -> WebModelContext {
        let actionID = service.definition.supportsConversation ? WebConversationContract.actionID : ModelServiceContract.start
        let conversation = try await WebConversation.open(service: service, owner: .provider(chatID ?? UUID()), actionID: actionID)
        Log.service.info("ModelService.open domain=\(service.domain) source=\(service.definition.repositoryID ?? "unknown") page=\(conversation.page.logLabel)")
        return WebModelContext(service: service, conversation: conversation, configuration: configuration)
    }

    private func mismatch(service: Service, configuration: Configuration) -> String? {
        if isClosed || !isPageCurrent { return "interrupted" }
        if service !== self.service { return "service" }
        if configuration.modelID != self.configuration.modelID { return "model" }
        if configuration != self.configuration { return "options" }
        if !supportsContinuation { return "unsupported" }
        if !hasContinuationCapacity { return "capacity" }
        return nil
    }

    private var isPageCurrent: Bool {
        conversation.isCurrent
    }

    func start(turn: Turn, attachments: [WebsiteAttachment]) async throws -> Generation {
        let files = turn.previousGenerationID == nil ? attachments : {
            let referenced = WebModelHistory.referencedFileNames(attachments.map(\.name), in: turn.messages, excluding: history)
            return attachments.filter { referenced.contains($0.name) }
        }()
        if !usesConversation { try await WebsiteAttachmentTransfer.stage(files, on: page.page) }
        var arguments: [String: JSONValue] = [
            "messages": .array(turn.messages),
            "attachments": .array(files.enumerated().map { index, attachment in
                .object(["id": .int(index), "name": .string(attachment.name), "mimeType": .string(attachment.mimeType)])
            }),
        ]
        let action: String
        if usesConversation {
            action = WebConversationContract.actionID
            arguments["operation"] = .string("submit")
            arguments["accountId"] = .null
            arguments["conversationRef"] = turn.previousGenerationID == nil ? .null : .string(conversation.id.uuidString)
            arguments["modelId"] = .string(configuration.modelID)
            arguments["options"] = .object(["temperature": configuration.temperature.map(JSONValue.double) ?? .null,
                                            "maxTokens": configuration.maxTokens.map(JSONValue.int) ?? .null])
        } else if let previous = turn.previousGenerationID {
            action = ModelServiceContract.resume
            arguments["previousGenerationId"] = .string(previous)
        } else {
            action = ModelServiceContract.start
            arguments["modelId"] = .string(configuration.modelID)
            arguments["options"] = .object(["temperature": configuration.temperature.map(JSONValue.double) ?? .null,
                                            "maxTokens": configuration.maxTokens.map(JSONValue.int) ?? .null])
        }
        let value = try await usesConversation
            ? conversation.call(.object(arguments), attachments: files)
            : invoke(action, .object(arguments))
        guard let fields = value.objectValue, let id = fields[usesConversation ? "submissionId" : "generationId"]?.stringValue, !id.isEmpty, id.count <= 200 else {
            throw WebsiteProviderError("Model service did not return a generation ID; submission may have occurred")
        }
        Log.service.info("ModelService.start domain=\(service.domain) action=\(action) generation=\(id) previous=\(turn.previousGenerationID ?? "none") turns=\(turn.messages.count) files=\(files.count) submission=\(fields["submission"]?.stringValue ?? "uncertain")")
        return Generation(id: id)
    }

    func read(_ generation: Generation, after cursor: Int) async throws -> JSONValue {
        if usesConversation {
            return try await conversation.call(.object([
                "operation": .string("read"), "submissionId": .string(generation.id),
                "after": .int(cursor), "waitMilliseconds": .int(1000),
            ]))
        }
        return try await invoke(ModelServiceContract.read, .object([
            "generationId": .string(generation.id), "after": .int(cursor), "waitMilliseconds": .int(1000),
        ]))
    }

    func finish(_ generation: Generation, history: [JSONValue], responseBytes: Int, chatID: UUID?) {
        completedGenerations += 1
        retainedResponseBytes += responseBytes
        if !hasContinuationCapacity {
            Log.service.info("ModelService.rollover domain=\(service.domain) generations=\(completedGenerations) responseBytes=\(retainedResponseBytes) page=\(page.logLabel)")
        }
        guard supportsContinuation, hasContinuationCapacity, !isClosed, isPageCurrent,
              let chatID, service.manager.isChatAttached(chatID) else {
            close()
            return
        }
        lastGenerationID = generation.id
        self.history = history
        service.manager.webModelContexts.updateValue(self, forKey: chatID)?.close()
        Log.service.info("ModelService.keep domain=\(service.domain) generation=\(generation.id) turns=\(history.count) page=\(page.logLabel)")
    }

    private func invoke(_ action: String, _ args: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        try checkPage()
        let value = try await conversation.invoke(action, args: args)
        try checkPage()
        return value
    }

    private func checkPage() throws {
        guard !isClosed, isPageCurrent else {
            throw WebsiteProviderError("Model service page was interrupted; the request was not resubmitted", kind: .network)
        }
    }

    func cancelAndClose(_ generation: Generation?) async {
        if let generation {
            let status = await Task { @MainActor in
                await withTaskGroup(of: JSONValue?.self) { group in
                    group.addTask { @MainActor in
                        if self.usesConversation {
                            return try? await self.conversation.call(.object(["operation": .string("cancel"), "submissionId": .string(generation.id)]))
                        }
                        return try? await self.invoke(ModelServiceContract.cancel, .object(["generationId": .string(generation.id)]))
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(3))
                        return nil
                    }
                    let result = await group.next() ?? nil
                    group.cancelAll()
                    return result
                }
            }.value
            Log.service.info("ModelService.cancel domain=\(service.domain) generation=\(generation.id) status=\(status?.objectValue?["status"]?.stringValue ?? "unconfirmed")")
        }
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        conversation.close()
        Log.service.info("ModelService.close domain=\(service.domain) page=\(page.logLabel)")
    }
}

import Foundation

extension ProfileProtocol {
    static func statusName(_ activity: Conversation.Activity) -> String {
        switch activity {
        case .idle(.read): "read"
        case .idle(.unread): "unread"
        case .idle(.stopped): "stopped"
        case .running(.thinking): "thinking"
        case .running(.streaming): "streaming"
        case .running(.awaiting(let action)): "awaiting.\(action)"
        }
    }

    struct ConversationView: Encodable {
        let id: String
        let title: String
        let providerId: String
        let model: ProviderModel
        let temporary: Bool
        let blocks: [Block]
        let isBusy: Bool
        let status: String
        let pendingPrompt: ConversationSnapshot.PendingPrompt?
        let turnEnding: TurnEndingRow?
        let followIntents: [FollowIntentRow]
        let queued: [QueuedRow]
        let services: [String]
        let parentId: String?
        let parentTitle: String?

        @MainActor
        init(_ conversation: Conversation, manager: ConversationManager) {
            id = conversation.id.uuidString
            title = conversation.title
            providerId = conversation.modelSelection.providerID
            model = conversation.model
            temporary = conversation.isTemporary
            blocks = conversation.transcript
            isBusy = conversation.isBusy
            status = ProfileProtocol.statusName(conversation.activity)
            if case .prompt(let prompt) = conversation.interaction {
                pendingPrompt = ConversationSnapshot.PendingPrompt(prompt)
            } else {
                pendingPrompt = nil
            }
            turnEnding = conversation.turnEnding.map(TurnEndingRow.init)
            followIntents = conversation.followIntents.map { FollowIntentRow(label: $0.label, message: $0.message) }
            queued = conversation.queuedMessages.map { QueuedRow(id: $0.id.uuidString, text: $0.text, attachments: $0.attachments.map(\.displayName)) }
            services = conversation.attachedServices.map(\.domain)
            parentId = conversation.parentID?.uuidString
            parentTitle = conversation.parentID.flatMap { manager.summary($0)?.displayTitle }
        }
    }

    struct TurnEndingRow: Encodable {
        let kind: String
        let message: String?

        init(_ ending: Conversation.TurnEnding) {
            switch ending {
            case .stopped:
                kind = "stopped"
                message = nil
            case .failed(let text):
                kind = "failed"
                message = text
            }
        }
    }

    struct FollowIntentRow: Encodable {
        let label: String
        let message: String
    }

    struct QueuedRow: Encodable {
        let id: String
        let text: String
        let attachments: [String]
    }

    struct ConversationViewResult: Encodable {
        let data: ConversationView
    }

    struct ConversationIDResult: Encodable {
        let conversationId: String
    }

    struct SkillRow: Encodable {
        let name: String
        let description: String
        let services: [String]
    }

    struct ListSkillsResult: Encodable {
        let skills: [SkillRow]
    }

    private static func uuid(_ value: String, _ label: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw RuntimeError.bridge("provide a full \(label) UUID") }
        return id
    }

    @MainActor
    private static func clientConversation(
        _ command: String,
        _ rawID: String,
        manager: ConversationManager,
        reply: ProfileRPC.Reply,
        _ body: @escaping @MainActor (Conversation) async throws -> Void
    ) {
        Task { @MainActor in
            do {
                let conversation = try await manager.loadForClient(try uuid(rawID, "conversation"))
                Log.agent.info("ProfileRPC.\(command) id=\(reply.id) conversation=\(conversation.id)")
                try await body(conversation)
            } catch {
                Log.agent.warning("ProfileRPC.\(command) failed id=\(reply.id) error=\(error.localizedDescription)")
                reply.failure(error.localizedDescription)
            }
        }
    }

    @MainActor
    private static func settledID(_ conversation: Conversation) async throws -> String {
        try await conversation.durablePreparation?.value
        return conversation.id.uuidString
    }

    @MainActor
    static func handleViewConversation(_ command: ConversationIDRequest, conversationManager: ConversationManager, reply: ProfileRPC.Reply) {
        Task { @MainActor in
            do {
                let conversation = try await conversationManager.loadForClient(try uuid(command.conversationId, "conversation"))
                conversation.markResponseRead(source: "client")
                reply.success(ConversationViewResult(data: ConversationView(conversation, manager: conversationManager)))
            } catch {
                reply.failure(error.localizedDescription)
            }
        }
    }

    @MainActor
    static func handleRenameConversation(_ command: RenameConversationRequest, conversationManager: ConversationManager, reply: ProfileRPC.Reply) {
        let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return reply.failure("provide a title") }
        clientConversation("conversations.rename", command.conversationId, manager: conversationManager, reply: reply) { conversation in
            conversationManager.rename(conversation.id, to: title)
            reply.success()
        }
    }

    @MainActor
    static func handlePinConversation(_ command: PinConversationRequest, conversationManager: ConversationManager, reply: ProfileRPC.Reply) {
        clientConversation("conversations.pin", command.conversationId, manager: conversationManager, reply: reply) { conversation in
            if conversationManager.summary(conversation.id)?.isFavorite != command.pinned {
                conversationManager.toggleFavorite(conversation.id)
            }
            reply.success()
        }
    }

    @MainActor
    static func handleDeleteConversation(_ command: ConversationIDRequest, conversationManager: ConversationManager, reply: ProfileRPC.Reply) {
        clientConversation("conversations.delete", command.conversationId, manager: conversationManager, reply: reply) { conversation in
            guard let deletion = conversationManager.delete(conversation.id) else {
                throw RuntimeError.bridge("unknown conversation: \(command.conversationId)")
            }
            try await deletion.value
            reply.success()
        }
    }

    @MainActor
    static func handleBranchConversation(_ command: ConversationBlockRequest, conversationManager: ConversationManager, reply: ProfileRPC.Reply) {
        clientConversation("conversations.branch", command.conversationId, manager: conversationManager, reply: reply) { conversation in
            guard let branched = await conversationManager.branch(from: conversation, atBlock: try uuid(command.blockId, "block")) else {
                throw RuntimeError.bridge("cannot branch from block \(command.blockId)")
            }
            reply.success(ConversationIDResult(conversationId: try await settledID(branched)))
        }
    }

    @MainActor
    static func handleRerunConversation(
        _ command: String,
        conversationId: String,
        blockId: String,
        text: String?,
        conversationManager: ConversationManager,
        reply: ProfileRPC.Reply
    ) {
        clientConversation(command, conversationId, manager: conversationManager, reply: reply) { conversation in
            guard let result = await conversation.rerun(at: try uuid(blockId, "block"), replacingText: text) else {
                throw RuntimeError.bridge("cannot rerun from block \(blockId)")
            }
            reply.success(ConversationIDResult(conversationId: try await settledID(result.replacement)))
        }
    }

    @MainActor
    static func handleRetryFailedConversation(_ command: ConversationIDRequest, conversationManager: ConversationManager, reply: ProfileRPC.Reply) {
        clientConversation("conversations.retryFailed", command.conversationId, manager: conversationManager, reply: reply) { conversation in
            guard conversation.retryFailedTurn() != nil else { throw RuntimeError.bridge("the last reply did not fail") }
            reply.success(ConversationIDResult(conversationId: conversation.id.uuidString))
        }
    }

    @MainActor
    static func handleCancelQueuedConversation(_ command: ConversationBlockRequest, conversationManager: ConversationManager, reply: ProfileRPC.Reply) {
        clientConversation("conversations.cancelQueued", command.conversationId, manager: conversationManager, reply: reply) { conversation in
            conversation.cancelQueued(try uuid(command.blockId, "queued message"))
            reply.success()
        }
    }

    @MainActor
    static func handleSetConversationServices(
        _ command: ConversationServicesRequest,
        conversationManager: ConversationManager,
        serviceManager: ServiceManager,
        reply: ProfileRPC.Reply
    ) {
        clientConversation("conversations.setServices", command.conversationId, manager: conversationManager, reply: reply) { conversation in
            let services = command.domains.compactMap { serviceManager.service(domain: $0) }
            let missing = command.domains.filter { domain in !services.contains { $0.domain == domain } }
            guard missing.isEmpty else { throw RuntimeError.bridge("unknown service: \(missing.joined(separator: ", "))") }
            conversation.setAttachedServices(services)
            reply.success()
        }
    }

    @MainActor
    static func handleListSkills(_ command: EmptyRequest, reply: ProfileRPC.Reply) {
        let skills = Skills.shared.userFacing.map { SkillRow(name: $0.name, description: $0.description, services: $0.services) }
        Log.agent.debug("ProfileRPC.skills.list id=\(reply.id) count=\(skills.count)")
        reply.success(ListSkillsResult(skills: skills))
    }

    @MainActor
    static func handleRichSend(_ command: SendConversationRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        Task { @MainActor in
            do {
                let id = try resolveClientConversationID(runtime.conversations, command.conversationId,
                                                       missing: "no active conversation; create one with conversations.new")
                let conversation = try await runtime.conversations.loadForClient(id)
                let invocation = try command.skill.map { name in
                    guard let skill = Skills.shared.skill(named: name) else { throw RuntimeError.bridge("unknown skill: \(name)") }
                    return UserSkillInvocation(skill: skill, argument: command.text)
                }
                var files: [FileItem] = []
                for attachment in command.attachments ?? [] {
                    files.append(try await conversation.importAttachment(data: attachment.data, suggestedName: attachment.name))
                }
                guard !command.text.isEmpty || !files.isEmpty || invocation != nil else { throw ConversationControlError.missingText }
                Log.agent.info("ProfileRPC.conversations.send id=\(reply.id) conversation=\(conversation.id) chars=\(command.text.count) attachments=\(files.count) skill=\(invocation?.skill.name ?? "none")")
                conversation.enqueue(command.text, attachments: files, skillInvocation: invocation)
                reply.success(SendConversationResult(conversationId: conversation.id.uuidString, outcome: .queued))
            } catch {
                Log.agent.warning("ProfileRPC.conversations.send failed id=\(reply.id) error=\(error.localizedDescription)")
                reply.failure(error.localizedDescription)
            }
        }
    }
}

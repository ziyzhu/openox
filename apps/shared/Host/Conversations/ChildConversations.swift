import Foundation

nonisolated enum ChildConversationState: Equatable, Sendable {
    enum Attention: String, Sendable {
        case approval, reply, login, verification, payment
    }

    case running
    case needsUser(Attention)
    case idle
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .running: "running"
        case .needsUser: "needsUser"
        case .idle: "idle"
        case .stopped: "stopped"
        case .failed: "failed"
        }
    }

    @MainActor
    init(_ conversation: Conversation) {
        switch conversation.activity {
        case .running(.awaiting(let action)):
            let attention: Attention = switch action {
            case .approval: .approval
            case .reply: .reply
            case .login: .login
            case .verification: .verification
            case .payment: .payment
            }
            self = .needsUser(attention)
        case .running: self = .running
        case .idle(.stopped): self = .stopped
        case .idle:
            if case .failed(let message) = conversation.turnEnding { self = .failed(message) } else { self = .idle }
        }
    }
}

nonisolated struct ChildConversationSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let state: ChildConversationState
    let updatedAt: Date

    var value: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id.uuidString),
            "title": .string(title),
            "state": .string(state.label),
            "updatedAt": .string(ISODate.string(from: updatedAt)),
        ]
        if case .needsUser(let attention) = state { fields["blocked"] = .string(attention.rawValue) }
        if case .failed(let message) = state { fields["error"] = .string(String(message.prefix(200))) }
        return .object(fields)
    }
}

@MainActor
extension ConversationManager {
    static let maximumRunningChildren = 3

    func children(of parent: Conversation) -> [ChildConversationSnapshot] {
        parent.childIDs.compactMap(childSnapshot)
    }

    func childSnapshot(_ id: UUID) -> ChildConversationSnapshot? {
        if let child = loadedConversation(id) {
            return ChildConversationSnapshot(id: child.id, title: child.metadata.displayTitle,
                state: ChildConversationState(child), updatedAt: child.metadata.activityDate)
        }
        guard let meta = summary(id) else { return nil }
        return ChildConversationSnapshot(id: meta.id, title: meta.displayTitle, state: .idle, updatedAt: meta.activityDate)
    }

    func startChild(prompt: String, title: String?, services: [Service], requestedBy parent: Conversation) async throws -> Conversation {
        guard parent.parentID == nil else {
            throw OxFunctionError(code: "delegation_unavailable", message: "ox.conversation.start: a child conversation cannot start another conversation.", recovery: "Do the work in this conversation.")
        }
        let running = children(of: parent).filter { $0.state == .running }.count
        guard running < Self.maximumRunningChildren else {
            throw OxFunctionError(code: "delegation_limit", message: "ox.conversation.start: at most \(Self.maximumRunningChildren) child conversations can run at once.", recovery: "Wait for a running child with ox.conversation.wait, or stop one, before starting another.")
        }
        let child = try await makeChildConversation(parentID: parent.id, in: parent.scope)
        if let title, !title.isEmpty { child.rename(to: title) }
        child.setAttachedServices(services)
        parent.addChild(child.id)
        child.enqueue(prompt)
        Log.session.info("delegation.start parent=\(parent.id) child=\(child.id) services=\(services.count) running=\(running + 1)")
        return child
    }

    func child(_ rawID: UUID, of parent: Conversation) async throws -> Conversation {
        guard parent.childIDs.contains(rawID) else {
            throw OxFunctionError(code: "not_found", message: "ox.conversation: \(rawID) is not a child of this conversation.", recovery: "Use an id from the child_conversations section or ox.conversation.children.")
        }
        guard contains(rawID), let child = try? await loadForClient(rawID) else {
            parent.removeChild(rawID)
            Log.session.info("delegation.missing parent=\(parent.id) child=\(rawID)")
            throw OxFunctionError(code: "not_found", message: "ox.conversation: child conversation \(rawID) was deleted.", recovery: "Tell the user the child conversation no longer exists.")
        }
        return child
    }

    func forgetDeletedChild(_ childID: UUID, parentID: UUID) {
        loadedConversation(parentID)?.removeChild(childID)
    }

    func stopChildren(of parent: Conversation) {
        for id in parent.childIDs {
            guard let child = loadedConversation(id), child.isBusy else { continue }
            child.stopCurrentTurn()
            Log.session.info("delegation.stop parent=\(parent.id) child=\(id) by=cascade")
        }
    }
}

import Foundation

extension Conversation {
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
}

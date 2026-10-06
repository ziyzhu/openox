import Foundation

extension Conversation {
    public func startConversation(prompt: String, title: String, purpose: String) async throws -> JSONValue? {
        try requireProfileMutation(Actions.conversationStart)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError.bridge("ox.conversation.start: prompt must not be empty.")
        }
        let args: JSONValue = .object(["prompt": .string(prompt), "title": .string(title)])
        return try await tracked(Actions.conversationStart, args, purpose: purpose) {
            try Task.checkCancellation()
            try self.requireProfileMutation(Actions.conversationStart)
            guard let manager = self.conversationManager else {
                throw RuntimeError.bridge("ox.conversation.start: an active Profile is required.")
            }
            let id = try manager.startConversation(prompt: prompt, title: title, requestedBy: self)
            return .object(["id": .string(id.uuidString)])
        }
    }

    public func deleteConversation(id: String, purpose: String) async throws -> JSONValue? {
        try requireProfileMutation(Actions.conversationDelete)
        guard let targetID = UUID(uuidString: id), let manager = conversationManager else {
            throw RuntimeError.bridge("ox.conversation.delete: a valid chat ID and active Profile are required.")
        }
        let target = try manager.deletionTarget(targetID, requestedBy: self)
        let args: JSONValue = .object([
            "id": .string(targetID.uuidString),
            "title": .string(target.displayTitle),
            "effect": .string(L10n.string("This removes the chat from your history. This can't be undone.")),
        ])
        return try await tracked(Actions.conversationDelete, args, purpose: purpose) {
            try Task.checkCancellation()
            _ = try manager.deletionTarget(targetID, requestedBy: self)
            guard let deletion = manager.delete(targetID) else {
                throw RuntimeError.bridge("ox.conversation.delete: the chat is no longer available.")
            }
            try await deletion.value
            Log.session.info("bridge.chat.delete caller=\(self.id) target=\(targetID)")
            return .object(["id": .string(targetID.uuidString), "deleted": .bool(true)])
        }
    }
}

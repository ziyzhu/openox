import Foundation

extension Chat {
    public func deleteChat(id: String, purpose: String) async throws -> JSONValue? {
        try requireProfileMutation(Actions.chatDelete)
        guard let targetID = UUID(uuidString: id), let manager = chatManager else {
            throw RuntimeError.bridge("ox.chat.delete: a valid chat ID and active Profile are required.")
        }
        let target = try manager.deletionTarget(targetID, requestedBy: self)
        let args: JSONValue = .object([
            "id": .string(targetID.uuidString),
            "title": .string(target.displayTitle),
            "effect": .string(L10n.string("This removes the chat from your history. This can't be undone.")),
        ])
        return try await tracked(Actions.chatDelete, args, purpose: purpose) {
            try Task.checkCancellation()
            _ = try manager.deletionTarget(targetID, requestedBy: self)
            guard let deletion = manager.delete(targetID) else {
                throw RuntimeError.bridge("ox.chat.delete: the chat is no longer available.")
            }
            try await deletion.value
            Log.session.info("bridge.chat.delete caller=\(self.id) target=\(targetID)")
            return .object(["id": .string(targetID.uuidString), "deleted": .bool(true)])
        }
    }
}

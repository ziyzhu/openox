import Foundation

extension Chat {
    public func startChat(prompt: String, title: String, purpose: String) async throws -> JSONValue? {
        try requireProfileMutation(Actions.chatStart)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError.bridge("ox.chat.start: prompt must not be empty.")
        }
        let args: JSONValue = .object(["prompt": .string(prompt), "title": .string(title)])
        return try await tracked(Actions.chatStart, args, purpose: purpose) {
            try Task.checkCancellation()
            try self.requireProfileMutation(Actions.chatStart)
            guard let manager = self.chatManager else {
                throw RuntimeError.bridge("ox.chat.start: an active Profile is required.")
            }
            let id = try manager.startChat(prompt: prompt, title: title, requestedBy: self)
            return .object(["id": .string(id.uuidString)])
        }
    }

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

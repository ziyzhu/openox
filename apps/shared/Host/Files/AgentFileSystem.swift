import Foundation

extension Conversation {
    var fileSystemMounts: [JSONValue] {
        let roots = VirtualFileSystem.hostRoots + ["mounts"]
        return roots.map { root in
            JSONValue.object(["path": .string(root), "access": .string(root == "tmp" ? "readOnly" : "readWrite")])
        } + [JSONValue.object(["path": .string(""), "access": .string("readOnly")])]
    }

    private func resolveConversationFilePath(_ path: String) throws -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let root = parts.first == "" ? 1 : 0
        guard parts.count > root + 1, ["conversations", "history", "chats"].contains(parts[root]),
              let uuid = UUID(uuidString: parts[root + 1]) else { return path }
        let reference = try DurableProfileStore.shared.reference(for: ConversationID(uuid), in: scope)
        parts[root] = "conversations"
        parts[root + 1] = String(reference.conversationID)
        if parts.count == root + 3 {
            if parts[root + 2] == "metadata" { parts[root + 2] = "conversation.json" }
            if ["history", "messages.jsonl"].contains(parts[root + 2]) { parts[root + 2] = "turns.jsonl" }
        }
        return parts.joined(separator: "/")
    }

    public func fileSystemOperation(name: String, arguments: JSONValue) async throws -> JSONValue? {
        let actions = ["list": Actions.fsList, "read": Actions.fsRead, "write": Actions.fsWrite,
                       "edit": Actions.fsEdit, "rm": Actions.fsRm, "mkdir": Actions.fsMkdir, "move": Actions.fsMove, "copy": Actions.fsCopy,
                       "glob": Actions.fsGlob, "grep": Actions.fsGrep]
        if name == "attach", let args = arguments.objectValue, let path = args["path"]?.stringValue {
            if path.lowercased().hasPrefix("http:") || path.lowercased().hasPrefix("https:") {
                return try await attachFileSystem(path: path, purpose: args["purpose"]?.stringValue ?? "Attach file")
            }
            try await durablePreparation?.value
            guard let route = durableRoute else { throw RuntimeError.bridge("Agent filesystem is unavailable") }
            let normalized = try await route.session.runtime.command(.object(["action": .string("filesystemValidate"),
                "operation": .string("read"), "arguments": .object(["path": .string(try resolveConversationFilePath(path)), "purpose": .string(args["purpose"]?.stringValue ?? "Attach file")]),
                "conversationID": .int(route.conversationID)]))
            guard let source = normalized.objectValue?["path"]?.stringValue else { throw RuntimeError.bridge("Invalid attachment path") }
            return try await attachFileSystem(path: source, purpose: args["purpose"]?.stringValue ?? "Attach file")
        }
        guard let action = actions[name], var args = arguments.objectValue else { throw RuntimeError.bridge("Invalid filesystem operation") }
        try await durablePreparation?.value
        guard let route = durableRoute else { throw RuntimeError.bridge("Agent filesystem is unavailable") }
        for key in ["path", "from", "to"] {
            if let path = args[key]?.stringValue { args[key] = .string(try resolveConversationFilePath(path)) }
        }
        let validated = try await route.session.runtime.command(.object(["action": .string("filesystemValidate"),
            "operation": .string(name), "arguments": .object(args), "profileID": .string(route.profileID.uuidString),
            "conversationID": .int(route.conversationID)]))
        guard let fields = validated.objectValue else { throw RuntimeError.bridge("Invalid agent filesystem request") }
        guard let path = fields["from"]?.stringValue ?? fields["path"]?.stringValue else {
            throw RuntimeError.bridge("Invalid agent filesystem request")
        }
        args = fields
        let purpose = args.removeValue(forKey: "purpose")?.stringValue ?? "\(name.capitalized) \(path)"
        var recorded = args
        if let base64 = recorded.removeValue(forKey: "base64")?.stringValue {
            recorded["bytes"] = .int(base64.utf8.count / 4 * 3)
        }
        return try await tracked(action, .object(recorded), purpose: purpose) {
            if ["write", "edit", "rm", "mkdir", "move", "copy"].contains(name) {
                for candidate in [path, args["to"]?.stringValue].compactMap({ $0 }) {
                    let root = candidate.split(separator: "/").first.map(String.init) ?? ""
                    let temporaryFiles = isTemporary && route.fileScope != nil && !["MEMORY.md", "skills", "history"].contains(root)
                    if !["mounts", "services"].contains(root), !temporaryFiles { try requireProfileMutation(action) }
                }
            }
            let result = try await route.session.host.fileSystem(owner: self, runtime: route.session.runtime,
                profileID: route.profileID, operation: name,
                arguments: .object(args.merging(["purpose": .string(purpose)]) { _, value in value }), mounts: fileSystemMounts)
            Log.session.info("bridge.fs.operation name=\(name) path=\(path) profile=\(route.profileID)")
            return result
        }
    }
}

import Foundation

extension Conversation {
    public func fileSystemOperation(name: String, arguments: JSONValue) async throws -> JSONValue? {
        let actions = ["list": Actions.fsList, "read": Actions.fsRead, "write": Actions.fsWrite,
                       "edit": Actions.fsEdit, "delete": Actions.fsDelete, "mkdir": Actions.fsMkdir,
                       "rmdir": Actions.fsRmdir, "move": Actions.fsMove, "copy": Actions.fsCopy,
                       "glob": Actions.fsGlob, "grep": Actions.fsGrep]
        if name == "attach", let args = arguments.objectValue, let path = args["path"]?.stringValue {
            if path.lowercased().hasPrefix("http:") || path.lowercased().hasPrefix("https:") {
                return try await attachFileSystem(path: path, purpose: args["purpose"]?.stringValue ?? "Attach file")
            }
            try await durablePreparation?.value
            guard let route = durableRoute else { throw RuntimeError.bridge("Agent filesystem is unavailable") }
            let normalized = try await route.session.runtime.command(.object(["action": .string("filesystemValidate"),
                "operation": .string("read"), "arguments": .object(["path": .string(path), "purpose": .string(args["purpose"]?.stringValue ?? "Attach file")]),
                "chatID": .string(route.nativeID.uuidString), "reference": route.reference?.value ?? .null]))
            guard let source = normalized.objectValue?["path"]?.stringValue else { throw RuntimeError.bridge("Invalid attachment path") }
            return try await attachFileSystem(path: source, purpose: args["purpose"]?.stringValue ?? "Attach file")
        }
        guard let action = actions[name], var args = arguments.objectValue else { throw RuntimeError.bridge("Invalid filesystem operation") }
        try await durablePreparation?.value
        guard let route = durableRoute else { throw RuntimeError.bridge("Agent filesystem is unavailable") }
        let validated = try await route.session.runtime.command(.object(["action": .string("filesystemValidate"),
            "operation": .string(name), "arguments": .object(args), "profileID": .string(route.profileID.uuidString),
            "chatID": .string(route.nativeID.uuidString), "reference": route.reference?.value ?? .null]))
        guard var fields = validated.objectValue else { throw RuntimeError.bridge("Invalid agent filesystem request") }
        if let historyPath = fields["path"]?.stringValue {
            var parts = historyPath.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "history", let id = Int(parts[1]), id >= 0, let profileID = scope.profileID {
                parts[1] = DurableConversationReference(profileID: profileID, conversationID: id).compatibilityID.description
                if parts.count == 3, parts[2] == "metadata" { parts[2] = "conversation.json" }
                if parts.count == 3, parts[2] == "history" { parts[2] = "turns.jsonl" }
                fields["path"] = .string(parts.joined(separator: "/"))
            }
        }
        guard let path = fields["from"]?.stringValue ?? fields["path"]?.stringValue else {
            throw RuntimeError.bridge("Invalid agent filesystem request")
        }
        args = fields
        let purpose = args.removeValue(forKey: "purpose")?.stringValue ?? "\(name.capitalized) \(path)"
        var roots = VirtualFileSystem.hostRoots
        if attachedServices.contains(where: { $0.domain == "ios:files" }) { roots.append("files") }
        let mounts = roots.map { root in
            JSONValue.object(["path": .string(root), "access": .string(root == "history" ? "readOnly" : "readWrite")])
        } + [JSONValue.object(["path": .string("chats"), "access": .string("readOnly")]),
             JSONValue.object(["path": .string(""), "access": .string("readOnly")])]
        return try await tracked(action, .object(args), purpose: purpose) {
            if ["write", "edit", "delete", "mkdir", "rmdir", "move", "copy"].contains(name) {
                for candidate in [path, args["to"]?.stringValue].compactMap({ $0 }) {
                    let root = candidate.split(separator: "/").first.map(String.init) ?? ""
                    let temporaryWorkspace = isTemporary && route.artifactScope != nil && !["MEMORY.md", "SOUL.md", "skills", "history"].contains(root)
                    if !["files", "services"].contains(root), !temporaryWorkspace { try requireProfileMutation(action) }
                    if root == "services", case .serviceItem(let kind, let domain, _) = try await fileSystemLocation(candidate) {
                        try await serviceManager.requireServiceSourceMutationEnabled(kind: kind, domain: domain, operation: "ox.fs.\(name)")
                    }
                }
            }
            let result = try await route.session.host.fileSystem(owner: self, runtime: route.session.runtime,
                profileID: route.profileID, operation: name,
                arguments: .object(args.merging(["purpose": .string(purpose)]) { _, value in value }), mounts: mounts)
            Log.session.info("bridge.fs.operation name=\(name) path=\(path) profile=\(route.profileID)")
            return result
        }
    }
}

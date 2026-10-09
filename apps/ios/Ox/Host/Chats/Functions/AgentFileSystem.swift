import Foundation

extension Conversation {
    public func fileSystemOperation(name: String, arguments: JSONValue) async throws -> JSONValue? {
        let actions = ["list": Actions.fsList, "read": Actions.fsRead, "write": Actions.fsWrite,
                       "edit": Actions.fsEdit, "delete": Actions.fsDelete, "glob": Actions.fsGlob, "grep": Actions.fsGrep]
        if name == "attach", let args = arguments.objectValue, let path = args["path"]?.stringValue {
            return try await attachFileSystem(path: path, purpose: args["purpose"]?.stringValue ?? "Attach file")
        }
        guard let action = actions[name], var args = arguments.objectValue else {
            throw RuntimeError.bridge("Invalid filesystem operation")
        }
        try await durablePreparation?.value
        guard let route = durableRoute else { throw RuntimeError.bridge("Agent filesystem is unavailable") }
        let validated = try await route.session.runtime.command(.object(["action": .string("filesystemValidate"),
            "operation": .string(name), "arguments": .object(args), "profileID": .string(route.profileID.uuidString)]))
        guard let fields = validated.objectValue, let path = fields["path"]?.stringValue else {
            throw RuntimeError.bridge("Invalid agent filesystem request")
        }
        args = fields
        let location = try await fileSystemLocation(path, defaultRoot: ["list", "glob", "grep"].contains(name))
        args["path"] = .string(location.path)
        let purpose = args.removeValue(forKey: "purpose")?.stringValue ?? "\(name.capitalized) \(location.path)"
        var roots = VirtualFileSystem.hostRoots
        if attachedServices.contains(where: { $0.domain == "ios:files" }) { roots.append("files") }
        let mounts = roots.map { root in
            JSONValue.object(["path": .string(root), "access": .string(root == "conversations" ? "readOnly" : "readWrite")])
        }
        return try await tracked(action, .object(args), purpose: purpose) {
            if ["write", "edit", "delete"].contains(name), case .serviceItem(let kind, let domain, _) = location {
                try await serviceManager.requireServiceSourceMutationEnabled(kind: kind, domain: domain, operation: "ox.fs.\(name)")
            }
            let result = try await route.session.host.fileSystem(owner: self, runtime: route.session.runtime,
                profileID: route.profileID, operation: name, arguments: .object(args), mounts: mounts)
            Log.session.info("bridge.fs.operation name=\(name) path=\(location.path) profile=\(route.profileID)")
            return result
        }
    }
}
